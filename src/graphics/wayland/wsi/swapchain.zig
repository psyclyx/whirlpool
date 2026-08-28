//! Per-surface Vulkan swapchain, staging, and presentation state.

const std = @import("std");
const graphics = @import("whirlpool-graphics");
const api = @import("api.zig");
const Context = @import("context.zig").Context;
const Staging = @import("staging.zig").Staging;
const vk = api.vk;
const check = api.check;
const barrier = api.barrier;

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
    staging: ?Staging = null,
    image_index: u32 = 0,
    prepared: bool = false,
    needs_recreate: bool = false,
    registered: bool = false,

    /// Create all Vulkan resources for one Wayland surface.
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
        self.assertValid();
        std.debug.assert(context.swapchain_count > 0);
        return self;
    }

    /// Drain presentation and release every per-surface resource.
    pub fn deinit(self: *Swapchain) void {
        self.assertValid();
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

    /// Rebuild extent-dependent resources after a resize or stale swapchain.
    pub fn recreate(self: *Swapchain, width: u32, height: u32) !void {
        self.assertValid();
        if (width == 0 or height == 0) return error.InvalidExtent;
        try self.waitForPresentation();
        self.destroySwapchain();
        self.destroyStaging();
        try self.createSwapchain(width, height);
        errdefer self.destroySwapchain();
        self.staging = try Staging.init(self.context, self.extent.width, self.extent.height);
        self.prepared = false;
        self.needs_recreate = false;
        self.assertValid();
        std.debug.assert(self.extent.width > 0 and self.extent.height > 0);
    }

    /// Acquire an image, upload the CPU frame, and submit the transfer. This
    /// explicit name keeps GPU work visible at every call site.
    pub fn uploadAndSubmit(self: *Swapchain, frame: graphics.skia.Frame) !void {
        self.assertValid();
        if (self.prepared) return error.FrameAlreadyPrepared;
        if (self.needs_recreate) try self.recreate(frame.width, frame.height);
        const packed_row = try self.validateFrame(frame);
        try self.acquireImage();
        self.staging.?.copy(frame, packed_row);
        try self.recordAndSubmit();
        self.prepared = true;
        self.assertValid();
        std.debug.assert(self.image_index < self.images.len);
    }

    fn validateFrame(self: *const Swapchain, frame: graphics.skia.Frame) !usize {
        if (frame.width != self.extent.width or frame.height != self.extent.height)
            return error.ExtentMismatch;
        const packed_row = try std.math.mul(usize, frame.width, 4);
        if (frame.row_bytes < packed_row) return error.InvalidFrameStride;
        const required = try std.math.mul(usize, frame.row_bytes, frame.height);
        if (frame.byte_len < required) return error.InvalidFramePixels;
        if (self.staging.?.bytes < packed_row * frame.height) return error.StagingBufferTooSmall;
        return packed_row;
    }

    fn acquireImage(self: *Swapchain) !void {
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
        if (self.image_index >= self.images.len) return error.InvalidImageIndex;
    }

    fn recordAndSubmit(self: *Swapchain) !void {
        std.debug.assert(self.image_index < self.images.len);
        std.debug.assert(self.image_index < self.render_finished.len);
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
            self.staging.?.buffer,
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
    }

    /// Infallible River commit edge. Out-of-date/suboptimal results are
    /// retained as swapchain state and handled by the next role recreation.
    pub fn commit(self: *Swapchain) void {
        self.assertValid();
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
        self.assertValid();
    }

    /// Nonblocking completion check used for lifetime and backpressure. Image
    /// reuse itself remains governed by vkAcquireNextImageKHR.
    pub fn submittedComplete(self: *Swapchain) !bool {
        self.assertValid();
        const status = vk.vkGetFenceStatus(self.context.device, self.fence);
        if (status == vk.VK_NOT_READY) return false;
        try check(status);
        return true;
    }

    /// A transaction may fail after another role has acquired an image. Drop
    /// that acquisition by rebuilding the swapchain without committing it.
    pub fn discard(self: *Swapchain) void {
        self.assertValid();
        if (!self.prepared) return;
        self.recreate(self.extent.width, self.extent.height) catch {};
        self.prepared = false;
        self.assertValid();
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

    fn destroyStaging(self: *Swapchain) void {
        if (self.staging) |*value| value.deinit(self.context);
        self.staging = null;
    }

    fn assertValid(self: *const Swapchain) void {
        std.debug.assert(self.images.len == self.render_finished.len);
        std.debug.assert((self.swapchain == null) == (self.images.len == 0));
        std.debug.assert((self.staging != null) == (self.swapchain != null));
        if (self.registered) std.debug.assert(self.context.swapchain_count > 0);
        if (self.prepared) {
            std.debug.assert(self.images.len > 0);
            std.debug.assert(self.image_index < self.images.len);
        }
    }
};
