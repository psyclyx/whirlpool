//! Minimal Vulkan WSI presenter owned by Whirlpool.
//!
//! The initial renderer uploads deterministic Snail CPU output into a
//! host-visible transfer buffer, then copies it into the Wayland swapchain.
//! This keeps presentation Vulkan-native while the persistent Snail GPU atlas
//! backend is built behind the same caller-owned device and queue.

const std = @import("std");
const wl = @import("wayland").client.wl;

const vk = @cImport({
    @cDefine("VK_USE_PLATFORM_WAYLAND_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

const max_swapchain_images = 8;

pub const Presenter = struct {
    instance: vk.VkInstance = null,
    surface: vk.VkSurfaceKHR = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,

    swapchain: vk.VkSwapchainKHR = null,
    images: [max_swapchain_images]vk.VkImage = .{null} ** max_swapchain_images,
    image_initialized: [max_swapchain_images]bool = .{false} ** max_swapchain_images,
    image_count: u32 = 0,
    swapchain_format: vk.VkFormat = vk.VK_FORMAT_B8G8R8A8_SRGB,
    swapchain_extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    resize_requested: bool = false,

    command_pool: vk.VkCommandPool = null,
    command_buffer: vk.VkCommandBuffer = null,
    image_available: vk.VkSemaphore = null,
    copy_finished: vk.VkSemaphore = null,
    in_flight: vk.VkFence = null,

    staging_buffer: vk.VkBuffer = null,
    staging_memory: vk.VkDeviceMemory = null,
    staging_mapped: ?*anyopaque = null,
    staging_capacity: usize = 0,

    device_name: [vk.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8 = .{0} ** vk.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE,

    pub fn init(
        display: *wl.Display,
        wayland_surface: *wl.Surface,
        width: u32,
        height: u32,
    ) !Presenter {
        var self: Presenter = .{};
        errdefer self.deinit();
        try self.createInstance();
        try self.createSurface(display, wayland_surface);
        try self.pickPhysicalDevice();
        try self.createDevice();
        try self.createCommands();
        try self.createSync();
        try self.createSwapchain(width, height);
        return self;
    }

    pub fn deinit(self: *Presenter) void {
        if (self.device != null) _ = vk.vkDeviceWaitIdle(self.device);
        self.destroyStaging();
        if (self.in_flight != null) vk.vkDestroyFence(self.device, self.in_flight, null);
        if (self.copy_finished != null) vk.vkDestroySemaphore(self.device, self.copy_finished, null);
        if (self.image_available != null) vk.vkDestroySemaphore(self.device, self.image_available, null);
        if (self.command_pool != null) vk.vkDestroyCommandPool(self.device, self.command_pool, null);
        self.destroySwapchain();
        if (self.device != null) vk.vkDestroyDevice(self.device, null);
        if (self.surface != null) vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.instance != null) vk.vkDestroyInstance(self.instance, null);
        self.* = .{};
    }

    pub fn deviceName(self: *const Presenter) []const u8 {
        return std.mem.sliceTo(&self.device_name, 0);
    }

    pub fn requestResize(self: *Presenter) void {
        self.resize_requested = true;
    }

    pub fn ensureSize(self: *Presenter, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return;
        if (!self.resize_requested and
            self.swapchain_extent.width == width and
            self.swapchain_extent.height == height) return;

        try check(vk.vkDeviceWaitIdle(self.device));
        self.destroySwapchain();
        try self.createSwapchain(width, height);
        self.resize_requested = false;
    }

    pub fn extent(self: *const Presenter) [2]u32 {
        return .{ self.swapchain_extent.width, self.swapchain_extent.height };
    }

    /// Present one tightly packed BGRA8 frame. False means the surface became
    /// out of date before submission and the caller should retry next tick.
    pub fn present(self: *Presenter, pixels: []const u8) !bool {
        const required = try frameByteLen(self.swapchain_extent);
        if (pixels.len != required) return error.InvalidPixelBuffer;
        try self.ensureStaging(required);

        try check(vk.vkWaitForFences(
            self.device,
            1,
            &self.in_flight,
            vk.VK_TRUE,
            std.math.maxInt(u64),
        ));

        var image_index: u32 = 0;
        const acquired = vk.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available,
            null,
            &image_index,
        );
        if (acquired == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            self.resize_requested = true;
            return false;
        }
        if (acquired != vk.VK_SUCCESS and acquired != vk.VK_SUBOPTIMAL_KHR) {
            return error.VulkanAcquireFailed;
        }

        const mapped: [*]u8 = @ptrCast(self.staging_mapped.?);
        @memcpy(mapped[0..required], pixels);

        try check(vk.vkResetFences(self.device, 1, &self.in_flight));
        try check(vk.vkResetCommandBuffer(self.command_buffer, 0));
        try self.recordCopy(image_index);

        const wait_stage = [1]vk.VkPipelineStageFlags{vk.VK_PIPELINE_STAGE_TRANSFER_BIT};
        const submit = std.mem.zeroInit(vk.VkSubmitInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.copy_finished,
        });
        try check(vk.vkQueueSubmit(self.queue, 1, &submit, self.in_flight));
        self.image_initialized[image_index] = true;

        const present_info = std.mem.zeroInit(vk.VkPresentInfoKHR, .{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.copy_finished,
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &image_index,
        });
        const presented = vk.vkQueuePresentKHR(self.queue, &present_info);
        if (presented == vk.VK_ERROR_OUT_OF_DATE_KHR or presented == vk.VK_SUBOPTIMAL_KHR) {
            self.resize_requested = true;
        } else if (presented != vk.VK_SUCCESS) {
            return error.VulkanPresentFailed;
        }
        if (acquired == vk.VK_SUBOPTIMAL_KHR) self.resize_requested = true;
        return true;
    }

    fn createInstance(self: *Presenter) !void {
        const app_info = std.mem.zeroInit(vk.VkApplicationInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "whirlpool-studio",
            .applicationVersion = vk.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = "whirlpool",
            .engineVersion = vk.VK_MAKE_VERSION(0, 1, 0),
            .apiVersion = vk.VK_API_VERSION_1_0,
        });
        const extensions = [_][*c]const u8{
            vk.VK_KHR_SURFACE_EXTENSION_NAME,
            vk.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
        };
        const create_info = std.mem.zeroInit(vk.VkInstanceCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = @as(u32, @intCast(extensions.len)),
            .ppEnabledExtensionNames = @as([*c]const [*c]const u8, @ptrCast(&extensions)),
        });
        try check(vk.vkCreateInstance(&create_info, null, &self.instance));
    }

    fn createSurface(
        self: *Presenter,
        display: *wl.Display,
        wayland_surface: *wl.Surface,
    ) !void {
        const create_info = std.mem.zeroInit(vk.VkWaylandSurfaceCreateInfoKHR, .{
            .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = @as(?*vk.struct_wl_display_1, @ptrCast(display)),
            .surface = @as(?*vk.struct_wl_surface_2, @ptrCast(wayland_surface)),
        });
        try check(vk.vkCreateWaylandSurfaceKHR(
            self.instance,
            &create_info,
            null,
            &self.surface,
        ));
    }

    fn pickPhysicalDevice(self: *Presenter) !void {
        var count: u32 = 0;
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, null));
        if (count == 0) return error.NoVulkanDevices;
        var devices: [16]vk.VkPhysicalDevice = .{null} ** 16;
        var actual: u32 = @min(count, devices.len);
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &actual, &devices));

        var fallback_device: vk.VkPhysicalDevice = null;
        var fallback_family: u32 = 0;
        for (devices[0..actual]) |device| {
            const family = self.findQueueFamily(device) orelse continue;
            var properties: vk.VkPhysicalDeviceProperties = undefined;
            vk.vkGetPhysicalDeviceProperties(device, &properties);
            if (properties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                self.selectDevice(device, family, properties);
                return;
            }
            if (fallback_device == null) {
                fallback_device = device;
                fallback_family = family;
            }
        }
        if (fallback_device == null) return error.NoSuitableVulkanDevice;
        var properties: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(fallback_device, &properties);
        self.selectDevice(fallback_device, fallback_family, properties);
    }

    fn selectDevice(
        self: *Presenter,
        device: vk.VkPhysicalDevice,
        family: u32,
        properties: vk.VkPhysicalDeviceProperties,
    ) void {
        self.physical_device = device;
        self.queue_family = family;
        const name = std.mem.sliceTo(&properties.deviceName, 0);
        const length = @min(name.len, self.device_name.len - 1);
        @memcpy(self.device_name[0..length], name[0..length]);
        self.device_name[length] = 0;
    }

    fn findQueueFamily(self: *Presenter, device: vk.VkPhysicalDevice) ?u32 {
        var count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
        var properties: [32]vk.VkQueueFamilyProperties = undefined;
        var actual: u32 = @min(count, properties.len);
        vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &actual, &properties);
        for (properties[0..actual], 0..) |property, index| {
            if (property.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT == 0) continue;
            var supports_present: vk.VkBool32 = vk.VK_FALSE;
            _ = vk.vkGetPhysicalDeviceSurfaceSupportKHR(
                device,
                @intCast(index),
                self.surface,
                &supports_present,
            );
            if (supports_present == vk.VK_TRUE) return @intCast(index);
        }
        return null;
    }

    fn createDevice(self: *Presenter) !void {
        const priority: f32 = 1.0;
        const queue_info = std.mem.zeroInit(vk.VkDeviceQueueCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        });
        const extension: [*c]const u8 = vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME;
        const create_info = std.mem.zeroInit(vk.VkDeviceCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = 1,
            .ppEnabledExtensionNames = &extension,
        });
        try check(vk.vkCreateDevice(
            self.physical_device,
            &create_info,
            null,
            &self.device,
        ));
        vk.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
    }

    fn createCommands(self: *Presenter) !void {
        const pool_info = std.mem.zeroInit(vk.VkCommandPoolCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_family,
        });
        try check(vk.vkCreateCommandPool(
            self.device,
            &pool_info,
            null,
            &self.command_pool,
        ));
        const allocate_info = std.mem.zeroInit(vk.VkCommandBufferAllocateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        });
        try check(vk.vkAllocateCommandBuffers(
            self.device,
            &allocate_info,
            &self.command_buffer,
        ));
    }

    fn createSync(self: *Presenter) !void {
        const semaphore_info = std.mem.zeroInit(vk.VkSemaphoreCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        });
        try check(vk.vkCreateSemaphore(
            self.device,
            &semaphore_info,
            null,
            &self.image_available,
        ));
        try check(vk.vkCreateSemaphore(
            self.device,
            &semaphore_info,
            null,
            &self.copy_finished,
        ));
        const fence_info = std.mem.zeroInit(vk.VkFenceCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        });
        try check(vk.vkCreateFence(
            self.device,
            &fence_info,
            null,
            &self.in_flight,
        ));
    }

    fn createSwapchain(self: *Presenter, width: u32, height: u32) !void {
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        try check(vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            self.physical_device,
            self.surface,
            &capabilities,
        ));
        if (capabilities.supportedUsageFlags & vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT == 0) {
            return error.SwapchainTransferUnsupported;
        }

        var format_count: u32 = 0;
        try check(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.physical_device,
            self.surface,
            &format_count,
            null,
        ));
        if (format_count == 0) return error.NoSurfaceFormats;
        var formats: [32]vk.VkSurfaceFormatKHR = undefined;
        var actual_formats: u32 = @min(format_count, formats.len);
        try check(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.physical_device,
            self.surface,
            &actual_formats,
            &formats,
        ));
        const surface_format = chooseSurfaceFormat(formats[0..actual_formats]) orelse
            return error.BgraSwapchainUnavailable;
        self.swapchain_format = surface_format.format;

        self.swapchain_extent = if (capabilities.currentExtent.width != std.math.maxInt(u32))
            capabilities.currentExtent
        else
            .{
                .width = std.math.clamp(
                    width,
                    capabilities.minImageExtent.width,
                    capabilities.maxImageExtent.width,
                ),
                .height = std.math.clamp(
                    height,
                    capabilities.minImageExtent.height,
                    capabilities.maxImageExtent.height,
                ),
            };

        var requested_images = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0) {
            requested_images = @min(requested_images, capabilities.maxImageCount);
        }
        requested_images = @min(requested_images, max_swapchain_images);
        const create_info = std.mem.zeroInit(vk.VkSwapchainCreateInfoKHR, .{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = requested_images,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = self.swapchain_extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = chooseCompositeAlpha(capabilities.supportedCompositeAlpha),
            .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = vk.VK_TRUE,
        });
        try check(vk.vkCreateSwapchainKHR(
            self.device,
            &create_info,
            null,
            &self.swapchain,
        ));

        var actual_images: u32 = 0;
        try check(vk.vkGetSwapchainImagesKHR(
            self.device,
            self.swapchain,
            &actual_images,
            null,
        ));
        if (actual_images > max_swapchain_images) return error.TooManySwapchainImages;
        self.image_count = actual_images;
        try check(vk.vkGetSwapchainImagesKHR(
            self.device,
            self.swapchain,
            &self.image_count,
            &self.images,
        ));
        self.image_initialized = .{false} ** max_swapchain_images;
        try self.ensureStaging(try frameByteLen(self.swapchain_extent));
    }

    fn destroySwapchain(self: *Presenter) void {
        if (self.swapchain != null) vk.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
        self.images = .{null} ** max_swapchain_images;
        self.image_initialized = .{false} ** max_swapchain_images;
        self.image_count = 0;
        self.swapchain_extent = .{ .width = 0, .height = 0 };
    }

    fn ensureStaging(self: *Presenter, required: usize) !void {
        if (self.staging_capacity >= required) return;
        if (self.staging_buffer != null) {
            try check(vk.vkDeviceWaitIdle(self.device));
            self.destroyStaging();
        }

        const buffer_info = std.mem.zeroInit(vk.VkBufferCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = required,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        });
        try check(vk.vkCreateBuffer(
            self.device,
            &buffer_info,
            null,
            &self.staging_buffer,
        ));
        errdefer self.destroyStaging();

        var requirements: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(self.device, self.staging_buffer, &requirements);
        const memory_info = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = try self.findMemoryType(
                requirements.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ),
        });
        try check(vk.vkAllocateMemory(
            self.device,
            &memory_info,
            null,
            &self.staging_memory,
        ));
        try check(vk.vkBindBufferMemory(
            self.device,
            self.staging_buffer,
            self.staging_memory,
            0,
        ));
        try check(vk.vkMapMemory(
            self.device,
            self.staging_memory,
            0,
            requirements.size,
            0,
            &self.staging_mapped,
        ));
        self.staging_capacity = required;
    }

    fn destroyStaging(self: *Presenter) void {
        if (self.device == null) return;
        if (self.staging_mapped != null) {
            vk.vkUnmapMemory(self.device, self.staging_memory);
        }
        if (self.staging_buffer != null) {
            vk.vkDestroyBuffer(self.device, self.staging_buffer, null);
        }
        if (self.staging_memory != null) {
            vk.vkFreeMemory(self.device, self.staging_memory, null);
        }
        self.staging_buffer = null;
        self.staging_memory = null;
        self.staging_mapped = null;
        self.staging_capacity = 0;
    }

    fn findMemoryType(
        self: *Presenter,
        allowed: u32,
        required: vk.VkMemoryPropertyFlags,
    ) !u32 {
        var properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &properties);
        for (0..properties.memoryTypeCount) |index| {
            const bit = @as(u32, 1) << @intCast(index);
            if (allowed & bit != 0 and
                properties.memoryTypes[index].propertyFlags & required == required)
            {
                return @intCast(index);
            }
        }
        return error.NoHostVisibleMemory;
    }

    fn recordCopy(self: *Presenter, image_index: u32) !void {
        const begin_info = std.mem.zeroInit(vk.VkCommandBufferBeginInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        try check(vk.vkBeginCommandBuffer(self.command_buffer, &begin_info));

        const to_transfer = std.mem.zeroInit(vk.VkImageMemoryBarrier, .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = @as(vk.VkImageLayout, @intCast(if (self.image_initialized[image_index])
                vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
            else
                vk.VK_IMAGE_LAYOUT_UNDEFINED)),
            .newLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)),
            .srcQueueFamilyIndex = std.math.maxInt(u32),
            .dstQueueFamilyIndex = std.math.maxInt(u32),
            .image = self.images[image_index],
            .subresourceRange = colorRange(),
        });
        vk.vkCmdPipelineBarrier(
            self.command_buffer,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &to_transfer,
        );

        const copy = std.mem.zeroInit(vk.VkBufferImageCopy, .{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .depth = 1,
            },
        });
        vk.vkCmdCopyBufferToImage(
            self.command_buffer,
            self.staging_buffer,
            self.images[image_index],
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &copy,
        );

        const to_present = std.mem.zeroInit(vk.VkImageMemoryBarrier, .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = 0,
            .oldLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)),
            .newLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR)),
            .srcQueueFamilyIndex = std.math.maxInt(u32),
            .dstQueueFamilyIndex = std.math.maxInt(u32),
            .image = self.images[image_index],
            .subresourceRange = colorRange(),
        });
        vk.vkCmdPipelineBarrier(
            self.command_buffer,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &to_present,
        );
        try check(vk.vkEndCommandBuffer(self.command_buffer));
    }
};

fn chooseSurfaceFormat(formats: []const vk.VkSurfaceFormatKHR) ?vk.VkSurfaceFormatKHR {
    for (formats) |format| {
        if (format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR and
            format.format == vk.VK_FORMAT_B8G8R8A8_SRGB) return format;
    }
    for (formats) |format| {
        if (format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR and
            format.format == vk.VK_FORMAT_B8G8R8A8_UNORM) return format;
    }
    return null;
}

fn chooseCompositeAlpha(supported: vk.VkCompositeAlphaFlagsKHR) vk.VkCompositeAlphaFlagBitsKHR {
    const choices = [_]vk.VkCompositeAlphaFlagBitsKHR{
        vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    };
    for (choices) |choice| {
        if (supported & @as(vk.VkCompositeAlphaFlagsKHR, choice) != 0) return choice;
    }
    return vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
}

fn colorRange() vk.VkImageSubresourceRange {
    return .{
        .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}

fn frameByteLen(extent_value: vk.VkExtent2D) !usize {
    const pixels = try std.math.mul(usize, extent_value.width, extent_value.height);
    return std.math.mul(usize, pixels, 4);
}

fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) return error.VulkanFailure;
}
