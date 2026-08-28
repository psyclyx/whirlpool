//! Composition root for a portable Wayland layer-surface host.
//!
//! It deliberately does not claim River's window-manager protocol. It
//! configures and presents retained content after each Wayland dispatch.

const std = @import("std");
const wayland = @import("wayland");
const client_api = @import("whirlpool-wayland-client");
const layer_shell = @import("whirlpool-wayland-layer-shell");
const script = @import("whirlpool-script");
const surface_presenter = @import("whirlpool-wayland-surface-presenter");
const wsi = @import("whirlpool-wayland-wsi");

pub const Runtime = struct {
    manager: layer_shell.Manager,
    surface: *layer_shell.Surface,
    context: *wsi.Context,
    presenter: surface_presenter.Presenter,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *client_api.Client,
        compositor: *wayland.client.wl.Compositor,
        config: layer_shell.Config,
        descriptor: *const script.config.SurfaceSpec,
    ) !Runtime {
        if (!std.mem.eql(u8, descriptor.provider, "layer-shell") or
            !std.mem.eql(u8, descriptor.role, "shell") or
            !std.mem.eql(u8, descriptor.placement, "default-output"))
            return error.UnsupportedSurfaceDescriptor;
        var manager = (try layer_shell.Manager.bind(client)) orelse
            return error.MissingLayerShellGlobal;
        errdefer manager.deinit();
        const surface = try manager.createSurface(allocator, compositor, config);
        errdefer surface.deinit();
        const context = try wsi.Context.init(allocator, @ptrCast(client.display));
        errdefer context.deinit();
        const presenter = try surface_presenter.Presenter.init(allocator, context, surface.wl_surface, descriptor);
        return .{ .manager = manager, .surface = surface, .context = context, .presenter = presenter };
    }

    /// Consume the newest acknowledged configure and present any dirty frame.
    /// Call once after dispatching pending Wayland events.
    pub fn presentIfReady(self: *Runtime) !bool {
        if (self.surface.closed) return error.SurfaceClosed;
        if (self.surface.takeConfigure()) |configure|
            try self.presenter.configure(configure.width, configure.height);
        return self.presenter.present();
    }

    pub fn update(self: *Runtime, update_value: script.program_loader.Update) !void {
        try self.presenter.update(update_value);
    }

    pub fn deinit(self: *Runtime) void {
        self.presenter.deinit();
        self.context.deinit();
        self.surface.deinit();
        self.manager.deinit();
        self.* = undefined;
    }
};

test "portable runtime is a distinct composition root" {
    try std.testing.expect(@sizeOf(Runtime) > @sizeOf(layer_shell.Manager));
}
