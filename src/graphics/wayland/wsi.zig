//! Shared Vulkan Wayland WSI context and per-surface swapchains.
//!
//! The compositor owns presentation. Whirlpool rasterizes with Skia into a
//! host-visible staging buffers, copies into acquired swapchain images, and
//! lets VK_KHR_wayland_surface/VK_KHR_swapchain perform the Wayland commit and
//! synchronization. One Context owns the instance/device/queue for a display;
//! each Swapchain owns only one wl_surface's frame resources. No dma-buf,
//! modifier, render-node, or syncobj protocol is part of this seam.

const std = @import("std");
const graphics = @import("whirlpool-graphics");

const vk = @cImport({
    @cDefine("VK_USE_PLATFORM_WAYLAND_KHR", "1");
    @cInclude("wayland-client-core.h");
    @cInclude("vulkan/vulkan.h");
});

const instance_extensions = [_][*:0]const u8{
    vk.VK_KHR_SURFACE_EXTENSION_NAME,
    vk.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
};
const device_extensions = [_][*:0]const u8{vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

/// Device-level Wayland WSI state shared by every surface on one display.
/// The heap allocation keeps pointers retained by per-surface swapchains
/// stable even when their platform runtimes move.
pub const Context = struct {
    allocator: std.mem.Allocator,
    display: *anyopaque,
    instance: vk.VkInstance = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,
    swapchain_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, display: *anyopaque) !*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .display = display };
        errdefer self.release();
        try self.createInstance();
        try self.pickDevice();
        try self.createDevice();
        return self;
    }

    pub fn deinit(self: *Context) void {
        std.debug.assert(self.swapchain_count == 0);
        const allocator = self.allocator;
        self.release();
        self.* = undefined;
        allocator.destroy(self);
    }

    fn release(self: *Context) void {
        if (self.device != null) {
            _ = vk.vkDeviceWaitIdle(self.device);
            vk.vkDestroyDevice(self.device, null);
        }
        if (self.instance != null) vk.vkDestroyInstance(self.instance, null);
        self.device = null;
        self.instance = null;
    }

    fn createInstance(self: *Context) !void {
        const app = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "whirlpool",
            .applicationVersion = 1,
            .pEngineName = "whirlpool",
            .engineVersion = 1,
            .apiVersion = vk.VK_API_VERSION_1_1,
        };
        const info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app,
            .enabledExtensionCount = instance_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&instance_extensions),
        };
        try check(vk.vkCreateInstance(&info, null, &self.instance));
    }

    fn pickDevice(self: *Context) !void {
        var count: u32 = 0;
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, null));
        const devices = try self.allocator.alloc(vk.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr));
        var score: u32 = 0;
        for (devices[0..count]) |device| {
            var family_count: u32 = 0;
            vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, null);
            const families = try self.allocator.alloc(vk.VkQueueFamilyProperties, family_count);
            defer self.allocator.free(families);
            vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, families.ptr);
            for (families[0..family_count], 0..) |family, index| {
                if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0) continue;
                if (vk.vkGetPhysicalDeviceWaylandPresentationSupportKHR(
                    device,
                    @intCast(index),
                    @ptrCast(self.display),
                ) != vk.VK_TRUE) continue;
                var properties: vk.VkPhysicalDeviceProperties = undefined;
                vk.vkGetPhysicalDeviceProperties(device, &properties);
                const candidate: u32 = switch (properties.deviceType) {
                    vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 4,
                    vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 3,
                    vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 2,
                    else => 1,
                };
                if (candidate > score) {
                    score = candidate;
                    self.physical_device = device;
                    self.queue_family = @intCast(index);
                }
            }
        }
        if (self.physical_device == null) return error.NoPresentDevice;
    }

    fn createDevice(self: *Context) !void {
        const priority: f32 = 1;
        const queue_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        const info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&device_extensions),
        };
        try check(vk.vkCreateDevice(self.physical_device, &info, null, &self.device));
        vk.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
    }
};

/// Surface-level WSI state. Command and synchronization objects are local so
/// River roles retain independent preflight/commit and retirement state.
pub const Swapchain = struct {
    context: *Context,
    allocator: std.mem.Allocator,
    wl_surface: *anyopaque,
    surface: vk.VkSurfaceKHR = null,
    format: vk.VkSurfaceFormatKHR = undefined,
    swapchain: vk.VkSwapchainKHR = null,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    images: []vk.VkImage = &.{},
    render_finished: []vk.VkSemaphore = &.{},
    image_available: vk.VkSemaphore = null,
    fence: vk.VkFence = null,
    command_pool: vk.VkCommandPool = null,
    command_buffer: vk.VkCommandBuffer = null,
    staging_buffer: vk.VkBuffer = null,
    staging_memory: vk.VkDeviceMemory = null,
    staging_mapped: ?*anyopaque = null,
    staging_bytes: usize = 0,
    image_index: u32 = 0,
    prepared: bool = false,
    needs_recreate: bool = false,
    registered: bool = false,

    pub fn init(
        context: *Context,
        surface: *anyopaque,
        width: u32,
        height: u32,
    ) !Swapchain {
        if (width == 0 or height == 0) return error.InvalidExtent;
        var self: Swapchain = .{
            .context = context,
            .allocator = context.allocator,
            .wl_surface = surface,
        };
        errdefer self.deinit();
        try self.createSurface();
        try self.requirePresentSupport();
        try self.chooseFormat();
        try self.createCommands();
        try self.recreate(width, height);
        context.swapchain_count += 1;
        self.registered = true;
        return self;
    }

    pub fn deinit(self: *Swapchain) void {
        self.waitForPresentation() catch {};
        self.destroySwapchain();
        self.destroyStaging();
        if (self.fence != null) vk.vkDestroyFence(self.context.device, self.fence, null);
        if (self.image_available != null) vk.vkDestroySemaphore(self.context.device, self.image_available, null);
        if (self.command_pool != null) vk.vkDestroyCommandPool(self.context.device, self.command_pool, null);
        if (self.surface != null) vk.vkDestroySurfaceKHR(self.context.instance, self.surface, null);
        if (self.registered) self.context.swapchain_count -= 1;
        self.* = undefined;
    }

    pub fn recreate(self: *Swapchain, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidExtent;
        try self.waitForPresentation();
        self.destroySwapchain();
        self.destroyStaging();
        try self.createSwapchain(width, height);
        errdefer self.destroySwapchain();
        try self.createStaging();
        self.prepared = false;
        self.needs_recreate = false;
    }

    /// Acquire an image, upload the CPU frame, and submit the transfer. This
    /// explicit name keeps GPU work visible at every call site.
    pub fn uploadAndSubmit(self: *Swapchain, frame: graphics.skia.Frame) !void {
        if (self.prepared) return error.FrameAlreadyPrepared;
        if (self.needs_recreate) try self.recreate(frame.width, frame.height);
        if (frame.width != self.extent.width or frame.height != self.extent.height)
            return error.ExtentMismatch;
        const packed_row = try std.math.mul(usize, frame.width, 4);
        if (frame.row_bytes < packed_row) return error.InvalidFrameStride;

        const fence_status = vk.vkWaitForFences(self.context.device, 1, &self.fence, vk.VK_TRUE, 0);
        if (fence_status == vk.VK_TIMEOUT) return error.NotReady;
        try check(fence_status);
        const acquired = vk.vkAcquireNextImageKHR(
            self.context.device,
            self.swapchain,
            0,
            self.image_available,
            null,
            &self.image_index,
        );
        if (acquired == vk.VK_NOT_READY or acquired == vk.VK_TIMEOUT) return error.NotReady;
        if (acquired == vk.VK_ERROR_OUT_OF_DATE_KHR) return error.SwapchainOutOfDate;
        if (acquired != vk.VK_SUCCESS and acquired != vk.VK_SUBOPTIMAL_KHR)
            return error.VulkanFailed;

        const mapped: [*]u8 = @ptrCast(self.staging_mapped orelse return error.InvalidMappedMemory);
        for (0..frame.height) |row| {
            const source_offset = row * frame.row_bytes;
            const target_offset = row * packed_row;
            @memcpy(mapped[target_offset..][0..packed_row], frame.pixels[source_offset..][0..packed_row]);
        }

        try check(vk.vkResetFences(self.context.device, 1, &self.fence));
        try check(vk.vkResetCommandBuffer(self.command_buffer, 0));
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &begin_info));
        barrier(
            self.command_buffer,
            self.images[self.image_index],
            vk.VK_IMAGE_LAYOUT_UNDEFINED,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0,
            vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );
        const region = vk.VkBufferImageCopy{
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .layerCount = 1,
            },
            .imageExtent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
        };
        vk.vkCmdCopyBufferToImage(
            self.command_buffer,
            self.staging_buffer,
            self.images[self.image_index],
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );
        barrier(
            self.command_buffer,
            self.images[self.image_index],
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            0,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        );
        try check(vk.vkEndCommandBuffer(self.command_buffer));
        const wait_stage: vk.VkPipelineStageFlags = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
        const signal = self.render_finished[self.image_index];
        const submit = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal,
        };
        try check(vk.vkQueueSubmit(self.context.queue, 1, &submit, self.fence));
        self.prepared = true;
    }

    /// Infallible River commit edge. Out-of-date/suboptimal results are
    /// retained as swapchain state and handled by the next role recreation.
    pub fn commit(self: *Swapchain) void {
        std.debug.assert(self.prepared);
        const signal = self.render_finished[self.image_index];
        const present = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signal,
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &self.image_index,
        };
        const result = vk.vkQueuePresentKHR(self.context.queue, &present);
        if (result == vk.VK_ERROR_OUT_OF_DATE_KHR or result == vk.VK_SUBOPTIMAL_KHR) {
            self.needs_recreate = true;
        } else if (result != vk.VK_SUCCESS) {
            std.log.err("Vulkan Wayland presentation failed: {d}", .{result});
        }
        self.prepared = false;
    }

    /// Nonblocking completion check used for lifetime and backpressure. Image
    /// reuse itself remains governed by vkAcquireNextImageKHR.
    pub fn submittedComplete(self: *Swapchain) !bool {
        const status = vk.vkGetFenceStatus(self.context.device, self.fence);
        if (status == vk.VK_NOT_READY) return false;
        try check(status);
        return true;
    }

    /// A transaction may fail after another role has acquired an image. Drop
    /// that acquisition by rebuilding the swapchain without committing it.
    pub fn discard(self: *Swapchain) void {
        if (!self.prepared) return;
        self.recreate(self.extent.width, self.extent.height) catch {};
        self.prepared = false;
    }

    /// Core Vulkan exposes no per-present completion fence. Resizing or
    /// destroying a presented swapchain therefore drains the shared queue;
    /// ordinary frame backpressure remains per-surface through `fence`.
    fn waitForPresentation(self: *Swapchain) !void {
        try check(vk.vkQueueWaitIdle(self.context.queue));
    }

    fn createSurface(self: *Swapchain) !void {
        const info = vk.VkWaylandSurfaceCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = @ptrCast(self.context.display),
            .surface = @ptrCast(self.wl_surface),
        };
        try check(vk.vkCreateWaylandSurfaceKHR(self.context.instance, &info, null, &self.surface));
    }

    fn requirePresentSupport(self: *Swapchain) !void {
        var supported: vk.VkBool32 = vk.VK_FALSE;
        try check(vk.vkGetPhysicalDeviceSurfaceSupportKHR(
            self.context.physical_device,
            self.context.queue_family,
            self.surface,
            &supported,
        ));
        if (supported != vk.VK_TRUE) return error.SurfaceNotSupported;
    }

    fn chooseFormat(self: *Swapchain) !void {
        var count: u32 = 0;
        try check(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(self.context.physical_device, self.surface, &count, null));
        if (count == 0) return error.NoSurfaceFormat;
        const formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, count);
        defer self.allocator.free(formats);
        try check(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(self.context.physical_device, self.surface, &count, formats.ptr));
        var selected: ?vk.VkSurfaceFormatKHR = null;
        if (count == 1 and formats[0].format == vk.VK_FORMAT_UNDEFINED) {
            selected = .{
                .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
                .colorSpace = formats[0].colorSpace,
            };
        }
        for (formats[0..count]) |format| {
            if (format.format == vk.VK_FORMAT_B8G8R8A8_UNORM and
                format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                selected = format;
                break;
            }
        }
        if (selected == null) for (formats[0..count]) |format| {
            if (format.format == vk.VK_FORMAT_B8G8R8A8_SRGB) {
                selected = format;
                break;
            }
        };
        self.format = selected orelse return error.NoBgraSurfaceFormat;
    }

    fn createCommands(self: *Swapchain) !void {
        const pool = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.context.queue_family,
        };
        try check(vk.vkCreateCommandPool(self.context.device, &pool, null, &self.command_pool));
        const allocation = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try check(vk.vkAllocateCommandBuffers(self.context.device, &allocation, &self.command_buffer));
        const semaphore = vk.VkSemaphoreCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        try check(vk.vkCreateSemaphore(self.context.device, &semaphore, null, &self.image_available));
        const fence = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        try check(vk.vkCreateFence(self.context.device, &fence, null, &self.fence));
    }

    fn createSwapchain(self: *Swapchain, width: u32, height: u32) !void {
        var caps: vk.VkSurfaceCapabilitiesKHR = undefined;
        try check(vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.context.physical_device, self.surface, &caps));
        if ((caps.supportedUsageFlags & vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT) == 0)
            return error.TransferDestinationUnsupported;
        self.extent = caps.currentExtent;
        if (self.extent.width == std.math.maxInt(u32)) {
            self.extent.width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width);
            self.extent.height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height);
        }
        var count = caps.minImageCount + 1;
        if (caps.maxImageCount != 0) count = @min(count, caps.maxImageCount);
        const alpha: vk.VkCompositeAlphaFlagBitsKHR = blk: {
            for ([_]vk.VkCompositeAlphaFlagBitsKHR{
                @intCast(vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR),
                @intCast(vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR),
                @intCast(vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR),
                @intCast(vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR),
            }) |candidate| if ((caps.supportedCompositeAlpha & candidate) != 0) break :blk candidate;
            return error.NoCompositeAlphaMode;
        };
        const info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = count,
            .imageFormat = self.format.format,
            .imageColorSpace = self.format.colorSpace,
            .imageExtent = self.extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform,
            .compositeAlpha = alpha,
            .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = vk.VK_TRUE,
        };
        try check(vk.vkCreateSwapchainKHR(self.context.device, &info, null, &self.swapchain));
        errdefer self.destroySwapchain();
        var actual: u32 = 0;
        try check(vk.vkGetSwapchainImagesKHR(self.context.device, self.swapchain, &actual, null));
        self.images = try self.allocator.alloc(vk.VkImage, actual);
        try check(vk.vkGetSwapchainImagesKHR(self.context.device, self.swapchain, &actual, self.images.ptr));
        self.render_finished = try self.allocator.alloc(vk.VkSemaphore, actual);
        @memset(self.render_finished, null);
        for (self.render_finished) |*item| {
            const semaphore = vk.VkSemaphoreCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
            try check(vk.vkCreateSemaphore(self.context.device, &semaphore, null, item));
        }
    }

    fn destroySwapchain(self: *Swapchain) void {
        for (self.render_finished) |item| if (item != null) vk.vkDestroySemaphore(self.context.device, item, null);
        self.allocator.free(self.render_finished);
        self.allocator.free(self.images);
        self.render_finished = &.{};
        self.images = &.{};
        if (self.swapchain != null) vk.vkDestroySwapchainKHR(self.context.device, self.swapchain, null);
        self.swapchain = null;
    }

    fn createStaging(self: *Swapchain) !void {
        errdefer self.destroyStaging();
        self.staging_bytes = try std.math.mul(usize, try std.math.mul(usize, self.extent.width, 4), self.extent.height);
        const info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = self.staging_bytes,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        };
        try check(vk.vkCreateBuffer(self.context.device, &info, null, &self.staging_buffer));
        var requirements: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(self.context.device, self.staging_buffer, &requirements);
        const memory_type = try self.findMemoryType(
            requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        const allocation = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        };
        try check(vk.vkAllocateMemory(self.context.device, &allocation, null, &self.staging_memory));
        try check(vk.vkBindBufferMemory(self.context.device, self.staging_buffer, self.staging_memory, 0));
        try check(vk.vkMapMemory(self.context.device, self.staging_memory, 0, self.staging_bytes, 0, &self.staging_mapped));
    }

    fn destroyStaging(self: *Swapchain) void {
        if (self.staging_mapped != null) vk.vkUnmapMemory(self.context.device, self.staging_memory);
        if (self.staging_buffer != null) vk.vkDestroyBuffer(self.context.device, self.staging_buffer, null);
        if (self.staging_memory != null) vk.vkFreeMemory(self.context.device, self.staging_memory, null);
        self.staging_mapped = null;
        self.staging_buffer = null;
        self.staging_memory = null;
        self.staging_bytes = 0;
    }

    fn findMemoryType(self: *Swapchain, bits: u32, required: vk.VkMemoryPropertyFlags) !u32 {
        var properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(self.context.physical_device, &properties);
        var index: u32 = 0;
        while (index < properties.memoryTypeCount) : (index += 1) {
            if ((bits & (@as(u32, 1) << @intCast(index))) != 0 and
                (properties.memoryTypes[index].propertyFlags & required) == required)
                return index;
        }
        return error.NoHostVisibleMemory;
    }
};

fn barrier(
    command: vk.VkCommandBuffer,
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    source_access: vk.VkAccessFlags,
    destination_access: vk.VkAccessFlags,
    source_stage: vk.VkPipelineStageFlags,
    destination_stage: vk.VkPipelineStageFlags,
) void {
    const value = vk.VkImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = source_access,
        .dstAccessMask = destination_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    vk.vkCmdPipelineBarrier(command, source_stage, destination_stage, 0, 0, null, 0, null, 1, &value);
}

fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) return error.VulkanFailed;
}

test "WSI separates shared device context from per-surface swapchain" {
    try std.testing.expect(@sizeOf(Context) < @sizeOf(Swapchain));
}
