//! Vulkan presenter for one ordinary Wayland surface.
//!
//! Role creation stays in the platform host. This object owns only retained
//! Lua content, rasterization, and the swapchain for the supplied wl_surface.
//! Its caller owns the shared device-level WSI context.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const graphics = @import("whirlpool-graphics");
const wsi = @import("whirlpool-wayland-wsi");

pub const Presenter = struct {
    allocator: std.mem.Allocator,
    context: *wsi.Context,
    surface: *wayland.client.wl.Surface,
    composition: host.surface_composition.Composition,
    renderer: graphics.skia.Renderer,
    swapchain: ?wsi.Swapchain = null,
    width: u32 = 0,
    height: u32 = 0,
    dirty: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        context: *wsi.Context,
        surface: *wayland.client.wl.Surface,
        descriptor: *const script.config.SurfaceSpec,
    ) !Presenter {
        var composition = try host.surface_composition.Composition.init(allocator, descriptor.content);
        errdefer composition.deinit();
        const renderer = try graphics.skia.Renderer.init(true);
        return .{
            .allocator = allocator,
            .context = context,
            .surface = surface,
            .composition = composition,
            .renderer = renderer,
        };
    }

    pub fn deinit(self: *Presenter) void {
        if (self.swapchain) |*swapchain| swapchain.deinit();
        self.renderer.deinit();
        self.composition.deinit();
        self.* = undefined;
    }

    pub fn configure(self: *Presenter, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidExtent;
        if (self.swapchain) |*swapchain|
            try swapchain.recreate(width, height)
        else
            self.swapchain = try wsi.Swapchain.init(
                self.context,
                @ptrCast(self.surface),
                width,
                height,
            );
        self.width = width;
        self.height = height;
        self.dirty = true;
    }

    pub fn update(self: *Presenter, update_value: script.program_loader.Update) !void {
        try self.composition.update(update_value);
        self.dirty = true;
    }

    /// Render and commit if content or extent changed. Returns whether a frame
    /// was committed; callers may treat NotReady as ordinary backpressure.
    pub fn present(self: *Presenter) !bool {
        if (!self.dirty) return false;
        const swapchain = if (self.swapchain) |*value| value else return false;

        var draw_list = try self.composition.snapshotAndLower(.{
            .width = self.width,
            .height = self.height,
        });
        defer draw_list.deinit();
        try self.renderer.begin(self.width, self.height, .{ 0, 0, 0, 0 });
        self.renderer.drawList(draw_list.drawList());
        const frame = try self.renderer.end();
        try swapchain.uploadAndSubmit(frame);
        swapchain.commit();
        self.dirty = false;
        return true;
    }
};

test "single-surface presenter has one optional swapchain" {
    try std.testing.expect(@sizeOf(Presenter) > @sizeOf(host.surface_composition.Composition));
}
