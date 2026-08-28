//! Portable layer-shell application startup.

const std = @import("std");
const wayland = @import("wayland");
const script = @import("whirlpool-script");
const wayland_client = @import("whirlpool-wayland-client");
const wayland_runtime = @import("whirlpool-wayland-runtime");
const layer_shell_runtime = @import("whirlpool-wayland-layer-shell-runtime");

pub fn run(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) !void {
    const path = config_path orelse return error.MissingConfig;
    var config = try script.config.load(allocator, io, path);
    defer config.deinit();
    const surface = config.surface("layer-shell", "shell") orelse
        return error.MissingLayerShellSurface;
    const bottom = std.mem.eql(u8, surface.edge, "bottom");
    const surface_height = if (surface.height != 0) surface.height else 40;
    const exclusive_zone: i32 = @intCast(if (surface.exclusive_zone != 0) surface.exclusive_zone else surface_height);

    var client = try wayland_client.Client.connect(allocator);
    defer client.deinit();
    const compositor = try bindCompositor(client);
    defer compositor.destroy();

    var layer = try layer_shell_runtime.Runtime.init(allocator, io, client, compositor, .{
        .height = surface_height,
        .anchor = .{ .top = !bottom, .bottom = bottom, .left = true, .right = true },
        .exclusive_zone = exclusive_zone,
    }, surface);

    var session: wayland_runtime.Session = undefined;
    try session.init(client);
    defer session.deinit();
    var layer_live = true;
    // This CLI owns the whole client connection. On any process-exit path,
    // stop its worker and drop local proxies before wl_display disconnects.
    defer if (layer_live) layer.abandon();
    session.setPollInterval(1000);
    layer.setWake(.{ .context = @ptrCast(&session), .run = wakeSession });
    var after_dispatch = AfterDispatch{ .runtime = &layer, .session = &session };
    session.setAfterDispatch(.{ .context = @ptrCast(&after_dispatch), .run = AfterDispatch.run });
    std.log.info("Portable layer-shell host connected", .{});
    session.run() catch |err| switch (err) {
        error.Disconnected => {
            std.log.info("Wayland display disconnected", .{});
            layer.abandon();
            layer_live = false;
        },
        else => return err,
    };
}

fn wakeSession(raw: ?*anyopaque) void {
    const session: *wayland_runtime.Session = @ptrCast(@alignCast(raw orelse return));
    session.loop.wake() catch {};
}

const AfterDispatch = struct {
    runtime: *layer_shell_runtime.Runtime,
    session: *wayland_runtime.Session,

    fn run(raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        try self.runtime.update(.{ .service = "tick" });
        _ = self.runtime.presentIfReady() catch |err| switch (err) {
            error.NotReady => return,
            error.SurfaceClosed => {
                try self.session.requestStop();
                return;
            },
            else => return err,
        };
    }
};

fn bindCompositor(client: *wayland_client.Client) !*wayland.client.wl.Compositor {
    const globals = try client.enumerateGlobals();
    for (globals) |global| if (std.mem.eql(u8, global.interface, "wl_compositor")) {
        return client.registry.bind(global.name, wayland.client.wl.Compositor, @min(global.version, 6)) catch return error.BindFailed;
    };
    return error.MissingCompositor;
}
