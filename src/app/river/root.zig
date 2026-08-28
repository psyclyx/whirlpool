//! River window-manager application startup and post-dispatch orchestration.

const std = @import("std");
const wayland = @import("wayland");
const wayland_client = @import("whirlpool-wayland-client");
const wayland_runtime = @import("whirlpool-wayland-runtime");
const river_live = @import("whirlpool-river-live");
const river_host_runtime = @import("whirlpool-river-host-runtime");
const river_role_lifecycle = @import("whirlpool-river-role-lifecycle");
const configured = @import("whirlpool-app-river-configured");
const presentation_app = @import("whirlpool-app-river-presentation");

pub fn run(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) !void {
    var client = try wayland_client.Client.connect(allocator);
    defer client.deinit();
    const compositor = try bindCompositor(client);
    defer compositor.destroy();

    var services = try configured.Services.init(allocator, io, client, config_path);
    defer services.deinit();

    var manager = try river_live.Manager.claim(client);
    var host_runtime = river_host_runtime.Runtime.initWithOptions(allocator, services.hostOptions());
    var host_runtime_live = true;
    defer if (host_runtime_live) host_runtime.deinit();
    try services.attach(&host_runtime);
    try host_runtime.attachManager(manager);
    var hooks = river_host_runtime.Runtime.hooks();
    hooks.context = @ptrCast(&host_runtime);
    try manager.setHooks(hooks);
    defer if (manager.state == .finished or manager.state == .unavailable)
        manager.deinit() catch |err| std.log.err("River manager cleanup failed: {s}", .{@errorName(err)})
    else
        manager.abandon();

    var presentation: presentation_app.Bridge = undefined;
    const role_hooks = try presentation.init(
        allocator,
        io,
        client,
        &host_runtime,
        services.surface("river", "shell"),
        services.surface("river", "decoration"),
    );
    var presentation_live = true;
    defer if (presentation_live) presentation.deinit() catch |err| std.log.err("River graphics cleanup failed: {s}", .{@errorName(err)});
    var roles = river_role_lifecycle.Runtime.init(allocator, manager, &host_runtime.adapter, compositor, role_hooks);
    var roles_live = true;
    defer if (roles_live) roles.deinit() catch |err| std.log.err("River role cleanup failed: {s}", .{@errorName(err)});
    presentation.bindRoles(&roles);

    var session: wayland_runtime.Session = undefined;
    try session.init(client);
    defer session.deinit();
    presentation.setWake(.{ .context = @ptrCast(&session), .run = wakeSession });
    defer presentation.clearWake();
    session.setPollInterval(16);
    var after_dispatch = AfterDispatch{
        .client = client,
        .runtime = &host_runtime,
        .roles = &roles,
        .services = &services,
        .presentation = &presentation,
    };
    session.setAfterDispatch(.{ .context = @ptrCast(&after_dispatch), .run = AfterDispatch.run });
    std.log.info("River host connected; waiting for River v5 transactions", .{});
    var disconnected = false;
    session.run() catch |err| switch (err) {
        error.Disconnected => {
            disconnected = true;
            std.log.info("River display disconnected", .{});
        },
        else => return err,
    };
    if (disconnected) {
        manager.hooks = .{};
        host_runtime.deinit();
        host_runtime_live = false;
        presentation.abandon();
        presentation_live = false;
        roles.abandon();
        roles_live = false;
    }
    if (manager.takeListenerError()) |err| return err;
}

fn wakeSession(raw: ?*anyopaque) void {
    const session: *wayland_runtime.Session = @ptrCast(@alignCast(raw orelse return));
    session.loop.wake() catch {};
}

const AfterDispatch = struct {
    client: *wayland_client.Client,
    runtime: *river_host_runtime.Runtime,
    roles: *river_role_lifecycle.Runtime,
    services: *configured.Services,
    presentation: *presentation_app.Bridge,

    fn run(raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        try self.services.drainActions(self.runtime);
        // A worker completion can race with River's render_start. Claim it
        // before draining the staged boundary so it can join this transaction
        // instead of demanding an otherwise unnecessary manage/render cycle.
        try self.presentation.pollReleases();
        try self.presentation.collectReady();
        try self.runtime.afterDispatch();
        // River transaction requests are latency-critical. Flush them before
        // any shell work so a slow renderer can never delay manage_dirty,
        // manage_finish, or render_finish reaching the compositor.
        self.client.flush() catch |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        };
        try self.presentation.pollReleases();
        try self.roles.reconcile();
        try self.presentation.present();
        // Presentation can queue a newly completed asynchronous frame after
        // the first host safe point. Drain its transaction request now.
        try self.runtime.afterDispatch();
        self.client.flush() catch |err| switch (err) {
            error.WouldBlock => {},
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
