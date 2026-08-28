//! GBM allocation of renderable DMA-BUF storage.
//!
//! A `Buffer` owns its GBM BO and exported plane file descriptors. Vulkan and
//! Wayland import duplicates of those descriptors; neither may consume the
//! originals retained here. Destruction is only legal after all importers have
//! stopped using the storage.

const std = @import("std");
const graphics = @import("whirlpool-graphics");

const c = @cImport({
    @cInclude("gbm.h");
});

pub const VulkanContext = @import("vulkan.zig").Context;
pub const VulkanImage = @import("vulkan.zig").Image;
pub const vk = @import("vulkan.zig").vk;

pub const max_planes = 4;
pub const argb8888: u32 = 0x3432_5241;
pub const xrgb8888: u32 = 0x3432_5258;
pub const modifier_linear: u64 = 0;
pub const modifier_invalid: u64 = 0x00ff_ffff_ffff_ffff;

pub const Plane = struct {
    fd: std.posix.fd_t,
    offset: u32,
    stride: u32,
};

pub const Device = struct {
    fd: std.posix.fd_t,
    gbm: *c.gbm_device,

    /// Open the render node identified by Vulkan's DRM properties. This keeps
    /// allocation and rendering on the same physical device on multi-GPU hosts.
    pub fn openRenderNode(render_major: i64, render_minor: i64) !Device {
        // Linux names render nodes by their DRM minor (normally 128+). The
        // major still must be present so an incomplete Vulkan query is not
        // silently accepted.
        if (render_major < 0 or render_minor < 0) return error.InvalidRenderNode;
        var path_storage: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_storage, "/dev/dri/renderD{d}", .{render_minor}) catch unreachable;
        const fd = std.c.open(path.ptr, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
            .NONBLOCK = true,
        });
        if (fd < 0) return error.RenderNodeNotFound;
        const gbm = c.gbm_create_device(fd) orelse {
            _ = std.c.close(fd);
            return error.GbmDeviceFailed;
        };
        return .{ .fd = fd, .gbm = gbm };
    }

    pub fn deinit(self: *Device) void {
        c.gbm_device_destroy(self.gbm);
        _ = std.c.close(self.fd);
        self.* = undefined;
    }
};

pub const Buffer = struct {
    bo: *c.gbm_bo,
    width: u32,
    height: u32,
    format: u32,
    modifier: u64,
    planes: [max_planes]Plane = undefined,
    plane_count: u32 = 0,

    /// Allocate one modifier-explicit render target. The caller supplies an
    /// already intersected preference list from Wayland and Vulkan.
    pub fn init(
        device: *Device,
        width: u32,
        height: u32,
        format: u32,
        modifiers: []const u64,
    ) !Buffer {
        if (width == 0 or height == 0) return error.InvalidExtent;
        if (modifiers.len == 0) return error.NoModifiers;
        const bo = c.gbm_bo_create_with_modifiers2(
            device.gbm,
            width,
            height,
            format,
            modifiers.ptr,
            @intCast(modifiers.len),
            c.GBM_BO_USE_RENDERING,
        ) orelse return error.GbmAllocationFailed;
        var self: Buffer = .{
            .bo = bo,
            .width = c.gbm_bo_get_width(bo),
            .height = c.gbm_bo_get_height(bo),
            .format = c.gbm_bo_get_format(bo),
            .modifier = c.gbm_bo_get_modifier(bo),
        };
        errdefer self.deinit();
        const plane_count = c.gbm_bo_get_plane_count(bo);
        if (plane_count == 0 or plane_count > max_planes)
            return error.InvalidPlaneCount;
        var index: u32 = 0;
        while (index < plane_count) : (index += 1) {
            const fd = c.gbm_bo_get_fd_for_plane(bo, @intCast(index));
            if (fd < 0) return error.ExportFailed;
            self.planes[index] = .{
                .fd = fd,
                .offset = c.gbm_bo_get_offset(bo, @intCast(index)),
                .stride = c.gbm_bo_get_stride_for_plane(bo, @intCast(index)),
            };
            self.plane_count += 1;
        }
        return self;
    }

    pub fn planeSlice(self: *const Buffer) []const Plane {
        return self.planes[0..self.plane_count];
    }

    pub fn deinit(self: *Buffer) void {
        var index: u32 = 0;
        while (index < self.plane_count) : (index += 1) _ = std.c.close(self.planes[index].fd);
        c.gbm_bo_destroy(self.bo);
        self.* = undefined;
    }
};

test "Vulkan DMA-BUF owners type check" {
    try std.testing.expect(@sizeOf(VulkanContext) > 0);
    try std.testing.expect(@sizeOf(VulkanImage) > 0);
}

test "hardware imports a GBM allocation into Vulkan" {
    if (std.c.getenv("WHIRLPOOL_DMABUF_TEST") == null) return;
    const allocator = std.testing.allocator;
    const context = try VulkanContext.init(allocator);
    defer context.deinit();
    const modifiers = try context.supportedModifiers(
        allocator,
        @import("vulkan.zig").vk.VK_FORMAT_B8G8R8A8_UNORM,
    );
    defer allocator.free(modifiers);
    try std.testing.expect(modifiers.len > 0);
    var chosen: ?usize = null;
    for (modifiers, 0..) |modifier, index| {
        if (modifier == modifier_linear) chosen = index;
    }
    const index = chosen orelse 0;
    var buffer = try Buffer.init(&context.gbm, 64, 64, argb8888, modifiers[index .. index + 1]);
    defer buffer.deinit();
    var image = try VulkanImage.init(context, &buffer);
    defer image.deinit();
    var renderer = try graphics.skia.GpuRenderer.init(context.skiaContext());
    defer renderer.deinit();
    try renderer.begin(image.skiaTarget(), .{ 0, 0, 0, 0 });
    renderer.drawList(.{ .ops = &.{.{ .rect = .{
        .rect = .{ .x = 4, .y = 4, .width = 56, .height = 56 },
        .color = .{ .r = 1, .g = 0, .b = 1, .a = 1 },
    } }} });
    try renderer.end(
        @intCast(@import("vulkan.zig").vk.VK_IMAGE_LAYOUT_GENERAL),
        @intCast(@import("vulkan.zig").vk.VK_QUEUE_FAMILY_FOREIGN_EXT),
    );
    image.markReleasedToWayland();
    // Exercise the FOREIGN -> graphics -> FOREIGN ownership cycle used after
    // a compositor release, not only the first UNDEFINED render.
    try renderer.begin(image.skiaTarget(), .{ 0, 0, 0, 0 });
    try renderer.end(
        @intCast(@import("vulkan.zig").vk.VK_IMAGE_LAYOUT_GENERAL),
        @intCast(@import("vulkan.zig").vk.VK_QUEUE_FAMILY_FOREIGN_EXT),
    );
    image.markReleasedToWayland();
}
