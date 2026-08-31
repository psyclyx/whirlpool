//! Configured River services and their native resource lifetimes.

const std = @import("std");
const wayland = @import("wayland");
const script = @import("whirlpool-script");
const wayland_client = @import("whirlpool-wayland-client");
const river_host = @import("whirlpool-river-host-runtime");
const river_keybindings = @import("whirlpool-river-keybindings");
const river_layout = @import("whirlpool-river-layout-runtime");
const river_policy = @import("whirlpool-river-policy-runtime");

/// Owns config-derived services that the River host borrows while running.
pub const Services = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    clock_origin: std.Io.Timestamp,
    commands: std.Io.Group = .init,
    config: ?script.config.Config = null,
    policy: ?river_policy.Runtime = null,
    layout: ?river_layout.Runtime = null,
    keybindings: ?river_keybindings.Runtime = null,

    /// Load optional user config and initialize its policy, layout, and keys.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        client: *wayland_client.Client,
        config_path: ?[]const u8,
    ) !Services {
        var self = Services{
            .allocator = allocator,
            .io = io,
            .clock_origin = std.Io.Clock.awake.now(io),
        };
        errdefer self.deinit();
        if (config_path) |path| {
            self.config = try script.config.load(allocator, io, path);
            const config = &self.config.?;
            self.layout = try river_layout.Runtime.init(allocator, config.layout_source, .{});
            self.keybindings = try river_keybindings.Runtime.init(allocator, client, config);
            std.log.info("Loaded Whirlpool config: {s} ({d} bindings)", .{ path, config.bindings.len });
        }
        self.policy = river_policy.Runtime.initDefault(allocator) catch |err| policy: {
            std.log.err("River Lua policy disabled: {s}", .{@errorName(err)});
            break :policy null;
        };
        return self;
    }

    /// Release configured services in reverse dependency order.
    pub fn deinit(self: *Services) void {
        self.commands.cancel(self.io);
        if (self.keybindings) |*value| value.deinit();
        if (self.layout) |*value| value.deinit();
        if (self.policy) |*value| value.deinit();
        if (self.config) |*value| value.deinit();
        self.* = undefined;
    }

    /// Build host hooks from services owned by this value.
    pub fn hostOptions(self: *Services) river_host.Options {
        std.debug.assert((self.config == null) == (self.layout == null));
        std.debug.assert((self.config == null) == (self.keybindings == null));
        var options: river_host.Options = .{};
        options.clock = .{ .context = @ptrCast(self), .monotonic_ms = monotonicMilliseconds };
        if (self.policy) |*policy| options.policy = .{
            .context = @ptrCast(policy),
            .budget = .{ .max_steps = policy.limits.max_instructions },
            .run = river_policy.Runtime.runHook,
        };
        if (self.layout) |*layout| options.layout = .{
            .context = @ptrCast(layout),
            .action = .{ .context = @ptrCast(layout), .run = river_layout.Runtime.actionHook },
            .build = river_layout.Runtime.buildHook,
            .project = river_layout.Runtime.projectHook,
        };
        return options;
    }

    fn monotonicMilliseconds(raw: ?*anyopaque) f64 {
        const self: *Services = @ptrCast(@alignCast(raw orelse unreachable));
        const elapsed = self.clock_origin.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds;
        return @as(f64, @floatFromInt(@max(elapsed, 0))) / 1_000_000.0;
    }

    /// Attach config-specific callbacks after the host has stable storage.
    pub fn attach(self: *Services, host: *river_host.Runtime) !void {
        const config = if (self.config) |*value| value else return;
        const keybindings = if (self.keybindings) |*value| value else unreachable;
        std.debug.assert(self.layout != null);
        try host.setConfig(config);
        try host.configureTags(&.{ "1", "2", "3", "4", "5", "6", "7", "8", "9" });
        if (config.surface("river", "shell")) |descriptor| {
            if (std.mem.eql(u8, descriptor.edge, "bottom")) try host.reserveBottom(descriptor.exclusive_zone);
        }
        try host.setSeatHook(.{ .context = @ptrCast(keybindings), .run = onSeat });
        try host.setManageHook(.{ .context = @ptrCast(keybindings), .run = onManage });
        try host.setSpawnHook(.{ .context = @ptrCast(self), .run = spawn });
    }

    /// Move queued key actions into the host at its post-dispatch safe point.
    pub fn drainActions(self: *Services, host: *river_host.Runtime) !void {
        const keybindings = if (self.keybindings) |*value| value else return;
        const actions = try keybindings.takeActions();
        defer self.allocator.free(actions);
        for (actions) |action| try host.queueConfiguredAction(action);
    }

    /// Return one configured surface borrowed from the owned config.
    pub fn surface(self: *const Services, placement: []const u8, role: []const u8) ?*const script.config.SurfaceSpec {
        std.debug.assert(placement.len > 0);
        std.debug.assert(role.len > 0);
        const config = if (self.config) |*value| value else return null;
        return config.surface(placement, role);
    }

    fn onSeat(raw: ?*anyopaque, seat: *wayland.client.river.SeatV1) !void {
        const keybindings: *river_keybindings.Runtime = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        try keybindings.onSeat(seat);
    }

    fn onManage(raw: ?*anyopaque) !void {
        const keybindings: *river_keybindings.Runtime = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        try keybindings.enablePending();
    }

    fn spawn(raw: ?*anyopaque, argv: []const []const u8) !void {
        if (argv.len == 0) return error.InvalidConfiguredSpawn;
        const self: *Services = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        std.debug.assert(argv[0].len > 0);
        const request = try SpawnRequest.init(self.allocator, argv);
        errdefer request.deinit();
        try self.commands.concurrent(self.io, spawnAndReap, .{ self, request });
    }

    fn spawnAndReap(self: *Services, request: *SpawnRequest) std.Io.Cancelable!void {
        defer request.deinit();
        var child = std.process.spawn(self.io, .{ .argv = request.argv }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.warn("configured command failed to start: {s}", .{@errorName(err)});
            return;
        };
        _ = child.wait(self.io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.warn("configured command wait failed: {s}", .{@errorName(err)});
            return;
        };
    }
};

const SpawnRequest = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,

    fn init(allocator: std.mem.Allocator, source: []const []const u8) !*SpawnRequest {
        const self = try allocator.create(SpawnRequest);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = try arena.allocator().alloc([]const u8, source.len);
        for (source, owned) |argument, *destination|
            destination.* = try arena.allocator().dupe(u8, argument);
        self.* = .{ .allocator = allocator, .arena = arena, .argv = owned };
        return self;
    }

    fn deinit(self: *SpawnRequest) void {
        const allocator = self.allocator;
        self.arena.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};
