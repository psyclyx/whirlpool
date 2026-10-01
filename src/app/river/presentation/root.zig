//! River role-to-presentation lifetime bridge.
//!
//! Feeds surface programs the services they draw from, all as objects of named
//! fields: `desktop` (tags, the layout's projected items, window metadata),
//! one service per configured measurement source, `pointer` events, and
//! `decoration` for window titles. It knows nothing about what a surface draws
//! or where: input goes to the program as events, and the program answers with
//! actions (`whirlpool.surface.act`) this bridge performs.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");
const wayland_client = @import("whirlpool-wayland-client");
const river_host_runtime = @import("whirlpool-river-host-runtime");
const river_role_lifecycle = @import("whirlpool-river-role-lifecycle");
const river_presenter_runtime = @import("whirlpool-river-presenter-runtime");
const status_app = @import("whirlpool-app-status");
const desktop_icons = @import("whirlpool-app-desktop-icons");

const Value = script.program_loader.Value;

/// Starts programs for surfaces that ask (`surface.act("spawn", ...)`).
pub const Spawner = struct {
    context: ?*anyopaque,
    run: *const fn (?*anyopaque, []const []const u8) anyerror!void,
};

/// Owns the optional graphics runtime and its River role callback context.
pub const Bridge = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    clock_origin: std.Io.Timestamp = undefined,
    graphics: ?*river_presenter_runtime.Runtime = null,
    status: ?*status_app.Service = null,
    icons: ?*desktop_icons.Service = null,
    context: Context = undefined,
    input_seats: std.ArrayList(*InputSeat) = .empty,
    generation: u64 = 1,

    /// Initialize graphics for a configured surface and return role hooks.
    pub fn init(
        self: *Bridge,
        allocator: std.mem.Allocator,
        io: std.Io,
        client: *wayland_client.Client,
        runtime: *river_host_runtime.Runtime,
        surface: ?*const script.config.SurfaceSpec,
        decoration_surface: ?*const script.config.SurfaceSpec,
        sources: []const script.config.SourceSpec,
        spawner: ?Spawner,
    ) !river_role_lifecycle.Hooks {
        self.* = .{};
        self.allocator = allocator;
        self.io = io;
        self.clock_origin = std.Io.Clock.awake.now(io);
        const spec = surface orelse return .{};
        self.graphics = try river_presenter_runtime.Runtime.init(allocator, io, client, .{
            .context = @ptrCast(runtime),
            .submit = queueCommit,
        }, spec, decoration_surface);
        errdefer {
            self.graphics.?.deinit() catch {};
            self.graphics = null;
        }
        self.status = try startSources(allocator, io, self.clock_origin, sources);
        errdefer {
            self.status.?.deinit();
            self.status = null;
        }
        self.icons = try desktop_icons.Service.init(allocator, io);
        errdefer {
            self.icons.?.deinit();
            self.icons = null;
        }
        try runtime.setSurfaceHooks(self.graphics.?.surfaceHooks());
        self.context = .{
            .allocator = allocator,
            .runtime = runtime,
            .roles = undefined,
            .graphics = self.graphics.?,
            .icons = self.icons.?,
            .spawner = spawner,
            .source_revisions = try allocator.alloc(u64, self.status.?.sourceCount()),
        };
        @memset(self.context.source_revisions, std.math.maxInt(u64));
        try self.bindInputSeats(client);
        return self.context.hooks();
    }

    /// Complete the callback context after role storage has a stable address.
    pub fn bindRoles(self: *Bridge, roles: *river_role_lifecycle.Runtime) void {
        if (self.graphics == null) return;
        std.debug.assert(self.context.graphics == self.graphics.?);
        self.context.roles = roles;
    }

    pub fn setWake(self: *Bridge, wake: river_presenter_runtime.Wake) void {
        if (self.graphics) |graphics| graphics.setWake(wake);
        if (self.status) |status| status.setWake(.{ .context = wake.context, .run = wake.run });
        if (self.icons) |icons| icons.setWake(.{ .context = wake.context, .run = wake.run });
    }

    pub fn clearWake(self: *Bridge) void {
        if (self.status) |status| status.clearWake();
        if (self.icons) |icons| icons.clearWake();
        if (self.graphics) |graphics| graphics.clearWake();
    }

    /// Poll graphics releases before role retirement reconciliation.
    pub fn pollReleases(self: *Bridge) !void {
        const graphics = self.graphics orelse return;
        _ = try graphics.pollReleases();
    }

    /// Perform surface actions, update what changed, and present every role.
    pub fn present(self: *Bridge) !void {
        const graphics = self.graphics orelse return;
        graphics.drainActions(&self.context, Context.perform);
        try self.context.refreshDesktop();
        try self.context.refreshSources(self.status.?);
        self.context.frame_ms = self.monotonicMilliseconds();
        try self.context.roles.forEachShell(&self.context, Context.updateFrameServices);
        try self.context.roles.forEachDecoration(&self.context, Context.updateDecorationServices);
        try self.collectReady();
    }

    fn monotonicMilliseconds(self: *const Bridge) f64 {
        const elapsed = self.clock_origin.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds;
        return @as(f64, @floatFromInt(@max(elapsed, 0))) / 1_000_000.0;
    }

    /// Claim worker-completed frames before an already-staged River render
    /// transaction is drained. This is deliberately separate from service
    /// updates: the worker may finish between the manage and render edges.
    pub fn collectReady(self: *Bridge) !void {
        const graphics = self.graphics orelse return;
        std.debug.assert(self.generation != 0);
        try graphics.presentAll(self.generation);
        self.generation +|= 1;
        if (self.generation == 0) return error.GenerationExhausted;
    }

    /// Release graphics after orderly role retirement.
    pub fn deinit(self: *Bridge) !void {
        for (self.input_seats.items) |seat| seat.deinit();
        self.input_seats.deinit(self.allocator);
        if (self.status) |status| status.deinit();
        if (self.icons) |icons| icons.deinit();
        if (self.graphics) |graphics| {
            self.context.deinit();
            try graphics.deinit();
        }
        self.* = undefined;
    }

    /// Drop graphics bookkeeping after transport loss.
    pub fn abandon(self: *Bridge) void {
        for (self.input_seats.items) |seat| seat.abandon();
        self.input_seats.deinit(self.allocator);
        if (self.status) |status| status.deinit();
        self.status = null;
        if (self.icons) |icons| icons.deinit();
        self.icons = null;
        if (self.graphics) |graphics| {
            self.context.deinit();
            graphics.abandon();
        }
        self.graphics = null;
    }

    fn bindInputSeats(self: *Bridge, client: *wayland_client.Client) !void {
        const globals = if (client.globals.items.len != 0) client.globals.items else try client.enumerateGlobals();
        for (globals) |global| {
            if (!std.mem.eql(u8, global.interface, "wl_seat")) continue;
            const proxy = try client.registry.bind(global.name, wayland.client.wl.Seat, @min(global.version, 9));
            errdefer proxy.release();
            const owner = try self.allocator.create(InputSeat);
            errdefer self.allocator.destroy(owner);
            owner.* = .{ .allocator = self.allocator, .context = &self.context, .seat = proxy };
            proxy.setListener(*InputSeat, InputSeat.onSeat, owner);
            try self.input_seats.append(self.allocator, owner);
        }
    }
};

/// Start the configured sources; an unknown kind is skipped with a warning.
fn startSources(allocator: std.mem.Allocator, io: std.Io, origin: std.Io.Timestamp, sources: []const script.config.SourceSpec) !*status_app.Service {
    var specs = std.ArrayList(status_app.Spec).empty;
    defer specs.deinit(allocator);
    for (sources) |source| {
        const kind = std.meta.stringToEnum(status_app.Kind, source.kind) orelse {
            std.log.warn("unknown source kind '{s}' for source '{s}'", .{ source.kind, source.name });
            continue;
        };
        try specs.append(allocator, .{
            .name = source.name,
            .kind = kind,
            .every_ms = source.every_ms,
            .keep_ms = source.keep_ms,
            .argv = source.argv,
        });
    }
    return status_app.Service.init(allocator, io, origin, specs.items);
}

const InputSeat = struct {
    allocator: std.mem.Allocator,
    context: *Context,
    seat: *wayland.client.wl.Seat,
    pointer: ?*wayland.client.wl.Pointer = null,
    output: ?host.types.OutputId = null,
    x: f64 = 0,
    y: f64 = 0,

    fn deinit(self: *InputSeat) void {
        if (self.pointer) |pointer| pointer.release();
        self.seat.release();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn abandon(self: *InputSeat) void {
        if (self.pointer) |pointer| @as(*wayland.client.wl.Proxy, @ptrCast(pointer)).destroy();
        @as(*wayland.client.wl.Proxy, @ptrCast(self.seat)).destroy();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn onSeat(seat: *wayland.client.wl.Seat, event: wayland.client.wl.Seat.Event, self: *InputSeat) void {
        switch (event) {
            .capabilities => |value| {
                if (value.capabilities.pointer and self.pointer == null) {
                    self.pointer = seat.getPointer() catch return;
                    self.pointer.?.setListener(*InputSeat, onPointer, self);
                } else if (!value.capabilities.pointer) {
                    if (self.pointer) |pointer| pointer.release();
                    self.pointer = null;
                    self.output = null;
                }
            },
            .name => {},
        }
    }

    /// Pointer input becomes `pointer` events for the shell program on that
    /// output: `{ type = "enter" | "motion" | "leave" | "button" | "scroll",
    /// x, y, button, pressed, dx, dy }` in surface coordinates.
    fn onPointer(_: *wayland.client.wl.Pointer, event: wayland.client.wl.Pointer.Event, self: *InputSeat) void {
        switch (event) {
            .enter => |value| {
                self.output = if (value.surface) |surface| self.context.roles.outputForSurface(surface) else null;
                self.x = wayland.client.wl.Fixed.toDouble(value.surface_x);
                self.y = wayland.client.wl.Fixed.toDouble(value.surface_y);
                self.send(.{ .kind = "enter" });
            },
            .leave => {
                self.send(.{ .kind = "leave" });
                self.output = null;
            },
            .motion => |value| {
                self.x = wayland.client.wl.Fixed.toDouble(value.surface_x);
                self.y = wayland.client.wl.Fixed.toDouble(value.surface_y);
                self.send(.{ .kind = "motion" });
            },
            .button => |value| self.send(.{
                .kind = "button",
                .button = value.button,
                .pressed = value.state == .pressed,
            }),
            .axis => |value| {
                const amount = wayland.client.wl.Fixed.toDouble(value.value);
                self.send(if (value.axis == .vertical_scroll) .{ .kind = "scroll", .dy = amount } else .{ .kind = "scroll", .dx = amount });
            },
            .frame, .axis_source, .axis_stop, .axis_discrete, .axis_value120, .axis_relative_direction => {},
        }
    }

    const Event = struct { kind: []const u8, button: u32 = 0, pressed: bool = false, dx: f64 = 0, dy: f64 = 0 };

    fn send(self: *InputSeat, event: Event) void {
        const output = self.output orelse return;
        const shell = self.context.shells.get(output.value) orelse return;
        const fields = [_]Value.Field{
            .{ .key = "type", .value = .{ .string = event.kind } },
            .{ .key = "x", .value = .{ .number = self.x } },
            .{ .key = "y", .value = .{ .number = self.y } },
            .{ .key = "button", .value = .{ .number = @floatFromInt(event.button) } },
            .{ .key = "pressed", .value = .{ .boolean = event.pressed } },
            .{ .key = "dx", .value = .{ .number = event.dx } },
            .{ .key = "dy", .value = .{ .number = event.dy } },
        };
        const values = [_]Value{.{ .object = &fields }};
        self.context.graphics.deliver(.{ .shell = shell }, .{ .service = "pointer", .values = &values }, .events) catch |err|
            std.log.warn("pointer event dropped: {s}", .{@errorName(err)});
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    runtime: *river_host_runtime.Runtime,
    roles: *river_role_lifecycle.Runtime,
    graphics: *river_presenter_runtime.Runtime,
    icons: *desktop_icons.Service,
    spawner: ?Spawner,
    frame_ms: f64 = 0,
    /// The shell surface on each output, by output id.
    shells: std.AutoHashMapUnmanaged(u64, host.types.ShellSurfaceId) = .empty,
    /// The desktop inputs each shell last received, by shell id.
    desktop_keys: std.AutoHashMapUnmanaged(u64, DesktopKey) = .empty,
    /// Per source, the revision every shell has; maxInt means none sent.
    source_revisions: []u64,
    /// Bumped when a shell appears, so it is sent every source.
    shells_created: u64 = 0,
    sources_sent_for: u64 = 0,

    /// What the desktop service depends on. While it is unchanged, nothing is
    /// recomputed: no layout projection runs, no payload is built.
    const DesktopKey = struct {
        manage_revision: u64,
        epoch: u64,
        metadata: u64,
        icons: u64,
        focused_output: ?wm.OutputId,
    };

    fn deinit(self: *Context) void {
        self.shells.deinit(self.allocator);
        self.desktop_keys.deinit(self.allocator);
        self.allocator.free(self.source_revisions);
    }

    pub fn hooks(self: *Context) river_role_lifecycle.Hooks {
        return .{
            .context = @ptrCast(self),
            .shell_created = onShellCreated,
            .shell_retire = onShellRetire,
            .decoration_created = onDecorationCreated,
            .decoration_retire = onDecorationRetire,
        };
    }

    /// An action a surface program asked for. `layout` runs a layout action
    /// on the surface's output; `spawn` starts a program. Others are ignored.
    fn perform(self: *Context, role: river_presenter_runtime.SurfaceRole, action: host.surface_composition.Action) void {
        const args = action.args;
        if (std.mem.eql(u8, action.name, "layout")) {
            const shell = switch (role) {
                .shell => |id| id,
                .decoration => return,
            };
            if (args.len == 0) return;
            const output = self.outputForShell(shell) orelse return;
            const wm_output = self.runtime.adapter.objects.wmOutputId(output) catch return;
            var rest: [script.layout_projection.max_action_args][]const u8 = undefined;
            const count = @min(args.len - 1, rest.len);
            for (args[1 .. 1 + count], 0..) |arg, index| rest[index] = arg;
            self.runtime.queueLayoutAction(wm_output, args[0], rest[0..count]) catch |err|
                std.log.warn("surface layout action '{s}' failed: {s}", .{ args[0], @errorName(err) });
        } else if (std.mem.eql(u8, action.name, "spawn")) {
            const spawner = self.spawner orelse return;
            if (args.len == 0) return;
            var argv: [script.config.MaxArguments][]const u8 = undefined;
            const count = @min(args.len, argv.len);
            for (args[0..count], 0..) |arg, index| argv[index] = arg;
            spawner.run(spawner.context, argv[0..count]) catch |err|
                std.log.warn("surface spawn failed: {s}", .{@errorName(err)});
        }
    }

    fn outputForShell(self: *const Context, shell: host.types.ShellSurfaceId) ?host.types.OutputId {
        var iterator = self.shells.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.*.value == shell.value) return .{ .value = entry.key_ptr.* };
        return null;
    }

    fn currentDesktopKey(self: *Context) DesktopKey {
        const world = self.runtime.adapter.worldView();
        return .{
            .manage_revision = self.runtime.adapter.revision,
            .epoch = world.epoch(),
            .metadata = self.runtime.adapter.objects.metadata_revision,
            .icons = self.icons.resolvedCount(),
            .focused_output = world.focusedOutput(),
        };
    }

    fn refreshDesktop(self: *Context) !void {
        const key = self.currentDesktopKey();
        var iterator = self.shells.iterator();
        while (iterator.next()) |entry| {
            const shell = entry.value_ptr.*;
            if (self.desktop_keys.get(shell.value)) |sent| if (std.meta.eql(sent, key)) continue;
            try self.sendDesktop(.{ .value = entry.key_ptr.* }, shell);
            try self.desktop_keys.put(self.allocator, shell.value, key);
        }
    }

    /// The `desktop` service for one output's shell:
    ///   tag      the active tag's ordinal (1-based)
    ///   tags     per tag: { occupied, active }
    ///   focused  whether this output has keyboard focus
    ///   items    the layout's projection, in order: { kind, label, detail,
    ///            focused, overlay, window, app_id, title, icon, action, args }
    fn sendDesktop(self: *Context, output_id: host.types.OutputId, shell_id: host.types.ShellSurfaceId) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const world = self.runtime.adapter.worldView();
        const wm_output = try self.runtime.adapter.objects.wmOutputId(output_id);
        const output = world.getOutput(wm_output) orelse return error.UnknownOutput;
        const active = world.tagOrdinal(output.active_tag) orelse return error.UnknownTag;

        const tag_count = world.liveTagCount();
        const tags = try arena.alloc(Value, tag_count);
        for (tags, 0..) |*tag, index| tag.* = .{ .object = try arena.dupe(Value.Field, &.{
            .{ .key = "occupied", .value = .{ .boolean = self.tagOccupied(world, world.tagAt(index)) } },
            .{ .key = "active", .value = .{ .boolean = index == active } },
        }) };

        var projection = try self.runtime.layoutProjection(self.allocator, wm_output);
        defer if (projection) |*value| value.deinit();
        const projected = if (projection) |*value| value.items.items else &.{};
        const items = try arena.alloc(Value, projected.len);
        for (projected, items) |*item, *destination| {
            var app_id: []const u8 = "";
            var title: []const u8 = "";
            var icon: []const u8 = "";
            if (item.window) |window| if (self.runtime.adapter.objects.wm_to_window.get(window)) |live_window| {
                const record = try self.runtime.adapter.objects.windowRecord(live_window);
                app_id = try arena.dupe(u8, record.app_id);
                title = try arena.dupe(u8, record.title);
                icon = try arena.dupe(u8, try self.icons.pathFor(record.app_id, record.pid));
            };
            const args = try arena.alloc(Value, item.arg_count);
            for (item.args[0..item.arg_count], args) |*arg, *value| value.* = .{ .string = try arena.dupe(u8, arg.slice()) };
            destination.* = .{ .object = try arena.dupe(Value.Field, &.{
                .{ .key = "kind", .value = .{ .string = try arena.dupe(u8, item.style.slice()) } },
                .{ .key = "label", .value = .{ .string = try arena.dupe(u8, item.text.slice()) } },
                .{ .key = "detail", .value = .{ .string = try arena.dupe(u8, item.detail.slice()) } },
                .{ .key = "focused", .value = .{ .boolean = item.focused } },
                .{ .key = "overlay", .value = .{ .boolean = item.overlay } },
                .{ .key = "window", .value = if (item.window) |window| .{ .number = @floatFromInt(window.raw()) } else .nil },
                .{ .key = "app_id", .value = .{ .string = app_id } },
                .{ .key = "title", .value = .{ .string = title } },
                .{ .key = "icon", .value = .{ .string = icon } },
                .{ .key = "action", .value = .{ .string = try arena.dupe(u8, item.action.slice()) } },
                .{ .key = "args", .value = .{ .array = args } },
            }) };
        }

        const fields = [_]Value.Field{
            .{ .key = "tag", .value = .{ .number = @floatFromInt(active + 1) } },
            .{ .key = "tags", .value = .{ .array = tags } },
            .{ .key = "focused", .value = .{ .boolean = world.focusedOutput() == wm_output } },
            .{ .key = "items", .value = .{ .array = items } },
        };
        const values = [_]Value{.{ .object = &fields }};
        try self.graphics.update(.{ .shell = shell_id }, .{ .service = "desktop", .values = &values });
    }

    /// Send each source that changed (or every source, to a new shell) to
    /// every shell, as a frame-class sample.
    fn refreshSources(self: *Context, status: *status_app.Service) !void {
        const everything = self.sources_sent_for != self.shells_created;
        self.sources_sent_for = self.shells_created;
        for (0..status.sourceCount()) |index| {
            if (!everything and status.revision(index) == self.source_revisions[index]) continue;
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            const encoded = try status.encode(Value, arena_state.allocator(), index);
            self.source_revisions[index] = encoded.revision;
            const values = [_]Value{encoded.value};
            var iterator = self.shells.valueIterator();
            while (iterator.next()) |shell| {
                self.graphics.deliver(.{ .shell = shell.* }, .{ .service = status.sourceName(index), .values = &values }, .sample) catch |err|
                    std.log.warn("source '{s}' not delivered: {s}", .{ status.sourceName(index), @errorName(err) });
            }
        }
    }

    pub fn updateFrameServices(raw: ?*anyopaque, _: host.types.OutputId, shell_id: host.types.ShellSurfaceId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        try self.graphics.requestFrame(.{ .shell = shell_id }, self.frame_ms);
    }

    /// The `decoration` service: `{ title, app_id, focused }`.
    pub fn updateDecorationServices(raw: ?*anyopaque, window_id: host.types.WindowId, decoration_id: host.types.DecorationId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        const record = try self.runtime.adapter.objects.windowRecord(window_id);
        const wm_window = record.wm_id orelse return;
        const world = self.runtime.adapter.worldView();
        _ = world.getWindow(wm_window) orelse return error.UnknownWindow;
        const fields = [_]Value.Field{
            .{ .key = "title", .value = .{ .string = record.title } },
            .{ .key = "app_id", .value = .{ .string = record.app_id } },
            .{ .key = "focused", .value = .{ .boolean = world.focusedWindow() == wm_window } },
        };
        const values = [_]Value{.{ .object = &fields }};
        try self.graphics.update(.{ .decoration = decoration_id }, .{ .service = "decoration", .values = &values });
    }

    fn tagOccupied(self: *const Context, world: *const wm.World, maybe_tag: ?wm.TagId) bool {
        const wanted = maybe_tag orelse return false;
        for (self.runtime.adapter.objects.window_order.items) |live_window| {
            const record = self.runtime.adapter.objects.windows.get(live_window) orelse continue;
            const wm_window = record.wm_id orelse continue;
            const window = world.getWindow(wm_window) orelse continue;
            if (window.tag == wanted and window.lifecycle == .managed) return true;
        }
        return false;
    }

    fn extent(width: i32, height: i32) !river_presenter_runtime.Extent {
        if (width <= 0 or height <= 0) return error.InvalidExtent;
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }

    fn shellExtent(self: *const Context, output: host.types.OutputId) !river_presenter_runtime.Extent {
        const size = (try self.roles.adapter.objects.outputSize(output)) orelse return error.OutputGeometryUnavailable;
        return extent(size.width, size.height);
    }

    fn decorationExtent(self: *const Context, window: host.types.WindowId) !river_presenter_runtime.Extent {
        const size = (try self.roles.adapter.objects.actualWindowSize(window)) orelse
            return error.WindowGeometryUnavailable;
        const record = try self.runtime.adapter.objects.windowRecord(window);
        const chrome = if (record.wm_id) |wm_window| self.runtime.windowChrome(wm_window) else null;
        const border_width = if (chrome) |value| value.border_width else 0;
        const configured_height = self.graphics.decoration_surface orelse return error.MissingDecorationSurface;
        const decoration_height = if (chrome) |value| value.decoration_height else std.math.cast(i32, configured_height.height) orelse return error.InvalidExtent;
        const framed_width = try std.math.add(
            i32,
            size.width,
            try std.math.mul(i32, border_width, 2),
        );
        return extent(framed_width, decoration_height);
    }
};

pub fn queueCommit(raw: ?*anyopaque, commit: host.river_coordinator.SubmittedCommit) !void {
    const runtime: *river_host_runtime.Runtime = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    try runtime.queueSubmittedCommit(commit);
}

fn onShellCreated(raw: ?*anyopaque, output: host.types.OutputId, shell: *wayland.client.river.ShellSurfaceV1, surface: *wayland.client.wl.Surface) !void {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    const shell_id = try self.roles.adapter.objects.shellSurfaceId(shell);
    const role_extent = try self.shellExtent(output);
    try self.graphics.createRole(.{ .shell = shell_id }, surface, role_extent);
    try self.shells.put(self.allocator, output.value, shell_id);
    self.shells_created +%= 1;
    const bar_height = @min(self.graphics.surface.height, role_extent.height);
    const input_region = try self.roles.compositor.createRegion();
    defer input_region.destroy();
    if (bar_height != 0) input_region.add(0, @intCast(role_extent.height - bar_height), @intCast(role_extent.width), @intCast(bar_height));
    surface.setInputRegion(input_region);
    std.log.info("River shell surface ready (output {d})", .{output.value});
}

fn onShellRetire(raw: ?*anyopaque, output: host.types.OutputId, shell: host.types.ShellSurfaceId) !river_role_lifecycle.RetirementStatus {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    _ = self.shells.remove(output.value);
    _ = self.desktop_keys.remove(shell.value);
    return retire(self, .{ .shell = shell });
}

fn onDecorationCreated(raw: ?*anyopaque, window: host.types.WindowId, id: host.types.DecorationId, _: *wayland.client.river.DecorationV1, surface: *wayland.client.wl.Surface) !void {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    try self.graphics.createRole(.{ .decoration = id }, surface, try self.decorationExtent(window));
}

fn onDecorationRetire(raw: ?*anyopaque, _: host.types.WindowId, id: host.types.DecorationId, inert: bool) !river_role_lifecycle.RetirementStatus {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    if (inert) self.graphics.markRoleInert(.{ .decoration = id });
    return retire(self, .{ .decoration = id });
}

fn retire(self: *Context, role: host.river_coordinator.SurfaceRole) !river_role_lifecycle.RetirementStatus {
    try self.runtime.retireSurfaceRole(role);
    return switch (try self.graphics.retireRole(role)) {
        .pending_release => .pending_release,
        .release_safe => .release_safe,
    };
}
