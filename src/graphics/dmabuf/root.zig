//! GBM allocation of renderable DMA-BUF storage.
//!
//! A `Buffer` owns its GBM BO and exported plane file descriptors. Vulkan and
//! Wayland import duplicates of those descriptors; neither may consume the
//! originals retained here. Destruction is only legal after all importers have
//! stopped using the storage.

const std = @import("std");

const c = @cImport({
    @cInclude("gbm.h");
});

pub const max_planes = 4;
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
        var minor: u32 = 128;
        while (minor < 192) : (minor += 1) {
            var path_storage: [64]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_storage, "/dev/dri/renderD{d}", .{minor}) catch unreachable;
            const fd = std.c.open(path.ptr, .{
                .ACCMODE = .RDWR,
                .CLOEXEC = true,
                .NONBLOCK = true,
            });
            if (fd < 0) continue;
            var stat: std.c.Stat = undefined;
            if (std.c.fstat(fd, &stat) != 0) {
                _ = std.c.close(fd);
                continue;
            }
            if (deviceMajor(stat.st_rdev) != render_major or
                deviceMinor(stat.st_rdev) != render_minor)
            {
                _ = std.c.close(fd);
                continue;
            }
            const gbm = c.gbm_create_device(fd) orelse {
                _ = std.c.close(fd);
                return error.GbmDeviceFailed;
            };
            return .{ .fd = fd, .gbm = gbm };
        }
        return error.RenderNodeNotFound;
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

// Linux dev_t encoding, equivalent to the glibc major/minor macros.
fn deviceMajor(device: std.c.dev_t) i64 {
    const value: u64 = @intCast(device);
    return @intCast(((value >> 8) & 0xfff) | ((value >> 32) & 0xffff_f000));
}

fn deviceMinor(device: std.c.dev_t) i64 {
    const value: u64 = @intCast(device);
    return @intCast((value & 0xff) | ((value >> 12) & 0xffff_ff00));
}

test "Linux device number decoding covers extended major and minor bits" {
    const major: u64 = 0x12345;
    const minor: u64 = 0x6789a;
    const encoded = ((major & 0xfff) << 8) |
        ((major & 0xffff_f000) << 32) |
        (minor & 0xff) |
        ((minor & 0xffff_ff00) << 12);
    try std.testing.expectEqual(@as(i64, major), deviceMajor(@intCast(encoded)));
    try std.testing.expectEqual(@as(i64, minor), deviceMinor(@intCast(encoded)));
}
