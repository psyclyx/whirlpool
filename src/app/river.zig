//! River window-manager application startup and post-dispatch orchestration.

const std = @import("std");
const wayland = @import("wayland");
const script = @import("whirlpool-script");
const wayland_client = @import("whirlpool-wayland-client");
const wayland_runtime = @import("whirlpool-wayland-runtime");
const river_live = @import("whirlpool-river-live");
const river_host_runtime = @import("whirlpool-river-host-runtime");
const river_keybindings = @import("whirlpool-river-keybindings");
const river_role_lifecycle = @import("whirlpool-river-role-lifecycle");
const river_presenter_runtime = @import("whirlpool-river-presenter-runtime");
const presentation_app = @import("river_presentation.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) !void {
    var config: ?script.config.Config = null;
    defer if (config) |*value| value.deinit();
    if (config_path) |path| {
        config = try script.config.load(allocator, io, path);
        std.log.info("Loaded Whirlpool config: {s} ({d} bindings)", .{ path, config.?.bindings.len });
    }

    var client = try wayland_client.Client.connect(allocator);
    defer client.deinit();
    const compositor = try bindCompositor(client);
    defer compositor.destroy();

    var manager = try river_live.Manager.claim(client);
    var keybindings_storage: river_keybindings.Runtime = undefined;
    var keybindings_active = false;
    defer if (keybindings_active) keybindings_storage.deinit();
    if (config) |*value| {
        keybindings_storage = try river_keybindings.Runtime.init(allocator, client, value);
        keybindings_active = true;
    }

    var policy = river_host_runtime.policy_runtime.Runtime.initDefault(allocator) catch |err| blk: {
        std.log.err("River Lua policy disabled: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (policy) |*loaded| loaded.deinit();
    var host_runtime = river_host_runtime.Runtime.init(allocator);
    var host_runtime_live = true;
    defer if (host_runtime_live) host_runtime.deinit();
    var layout_storage: river_host_runtime.layout_runtime.Runtime = undefined;
    var layout_active = false;
    defer if (layout_active) layout_storage.deinit();
    var spawn_context = SpawnContext{ .io = io };
    if (policy) |*loaded| host_runtime.setPolicy(loaded);
    if (config) |*value| {
        layout_storage = try river_host_runtime.layout_runtime.Runtime.init(allocator, value.layout_source, .{});
        layout_active = true;
        host_runtime.setLayout(&layout_storage);
        try host_runtime.setConfig(value);
        try host_runtime.setSeatHook(.{ .context = @ptrCast(&keybindings_storage), .run = onConfiguredSeat });
        try host_runtime.setManageHook(.{ .context = @ptrCast(&keybindings_storage), .run = onConfiguredManage });
        try host_runtime.setSpawnHook(.{ .context = @ptrCast(&spawn_context), .run = spawnConfigured });
    }
    try host_runtime.attachManager(manager);
    var hooks = river_host_runtime.Runtime.hooks();
    hooks.context = @ptrCast(&host_runtime);
    try manager.setHooks(hooks);
    defer if (manager.state == .finished or manager.state == .unavailable)
        manager.deinit() catch |err| std.log.err("River manager cleanup failed: {s}", .{@errorName(err)})
    else
        manager.abandon();

    var presentation: ?*river_presenter_runtime.Runtime = null;
    defer if (presentation) |value| value.deinit() catch |err| std.log.err("River graphics cleanup failed: {s}", .{@errorName(err)});
    var presentation_context: presentation_app.Context = undefined;
    var role_hooks: river_role_lifecycle.Hooks = .{};
    const surface = configuredSurface(&config);
    if (surface != null) {
        presentation = try river_presenter_runtime.Runtime.init(allocator, client, .{
            .context = @ptrCast(&host_runtime),
            .submit = presentation_app.queueCommit,
        }, surface.?);
        try host_runtime.setSurfaceHooks(presentation.?.surfaceHooks());
        presentation_context = .{ .runtime = &host_runtime, .roles = undefined, .graphics = presentation.? };
        role_hooks = presentation_context.hooks();
    }
    var roles = river_role_lifecycle.Runtime.init(allocator, manager, &host_runtime.adapter, compositor, role_hooks);
    var roles_live = true;
    defer if (roles_live) roles.deinit() catch |err| std.log.err("River role cleanup failed: {s}", .{@errorName(err)});
    if (presentation != null) presentation_context.roles = &roles;

    var session: wayland_runtime.Session = undefined;
    try session.init(client);
    defer session.deinit();
    session.setPollInterval(16);
    var after_dispatch = AfterDispatch{
        .allocator = allocator,
        .runtime = &host_runtime,
        .roles = &roles,
        .keybindings = if (keybindings_active) &keybindings_storage else null,
        .presentation = if (presentation != null) &presentation_context else null,
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
        if (presentation) |value| {
            value.abandon();
            presentation = null;
        }
        roles.abandon();
        roles_live = false;
    }
    if (manager.takeListenerError()) |err| return err;
}

const AfterDispatch = struct {
    allocator: std.mem.Allocator,
    runtime: *river_host_runtime.Runtime,
    roles: *river_role_lifecycle.Runtime,
    keybindings: ?*river_keybindings.Runtime,
    presentation: ?*presentation_app.Context,
    generation: u64 = 1,

    fn run(raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        if (self.keybindings) |keybindings| {
            const actions = try keybindings.takeActions();
            defer self.allocator.free(actions);
            for (actions) |action_index| try self.runtime.queueConfiguredAction(action_index);
        }
        try self.runtime.afterDispatch();
        if (self.presentation) |presentation| _ = try presentation.graphics.pollReleases();
        try self.roles.reconcile();
        if (self.presentation) |presentation| {
            try presentation.roles.forEachShell(presentation, presentation_app.Context.updateShellServices);
            try presentation.graphics.presentAll(self.generation);
            self.generation +|= 1;
            if (self.generation == 0) return error.GenerationExhausted;
        }
    }
};

fn configuredSurface(config: *const ?script.config.Config) ?*const script.config.SurfaceSpec {
    if (config.*) |*value| return value.surface("river", "shell");
    return null;
}

fn onConfiguredSeat(raw: ?*anyopaque, seat: *wayland.client.river.SeatV1) !void {
    const keybindings: *river_keybindings.Runtime = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    try keybindings.onSeat(seat);
}

fn onConfiguredManage(raw: ?*anyopaque) !void {
    const keybindings: *river_keybindings.Runtime = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    try keybindings.enablePending();
}

const SpawnContext = struct { io: std.Io };

fn spawnConfigured(raw: ?*anyopaque, argv: []const []const u8) !void {
    if (argv.len == 0) return error.InvalidConfiguredSpawn;
    const context: *SpawnContext = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    const child = try std.process.spawn(context.io, .{ .argv = argv });
    const thread = std.Thread.spawn(.{}, reapConfiguredChild, .{ child, context.io }) catch |err| {
        var owned = child;
        owned.kill(context.io);
        return err;
    };
    thread.detach();
}

fn reapConfiguredChild(child: std.process.Child, io: std.Io) void {
    var owned = child;
    _ = owned.wait(io) catch |err| std.log.warn("configured command wait failed: {s}", .{@errorName(err)});
}

fn bindCompositor(client: *wayland_client.Client) !*wayland.client.wl.Compositor {
    const globals = try client.enumerateGlobals();
    for (globals) |global| if (std.mem.eql(u8, global.interface, "wl_compositor")) {
        return client.registry.bind(global.name, wayland.client.wl.Compositor, @min(global.version, 6)) catch return error.BindFailed;
    };
    return error.MissingCompositor;
}
