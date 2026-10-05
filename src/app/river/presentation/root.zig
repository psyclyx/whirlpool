//! River role-to-presentation lifetime bridge.
//!
//! Feeds surface programs the services they draw from, all as objects of named
//! fields: `desktop` (tags, the layout's projected items, window metadata),
//! one service per configured measurement source, `pointer` events for the
//! shell or decoration under the pointer, and `decoration` for its window. It knows nothing about what a surface draws
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
const desktop_entries = @import("whirlpool-app-desktop-entries");

const Value = script.program_loader.Value;

/// Starts programs for surfaces that ask (`surface.act("spawn", ...)`).
pub const SurfaceSpec = script.config.SurfaceSpec;
pub const max_output_shells = river_host_runtime.max_output_shells;

/// The configured surface drawn on layout marks of a name, if any.
pub const MarkSurfaces = struct {
    context: ?*anyopaque = null,
    find: ?*const fn (?*anyopaque, []const u8) ?*const script.config.SurfaceSpec = null,

    fn get(self: MarkSurfaces, name: []const u8) ?*const script.config.SurfaceSpec {
        return (self.find orelse return null)(self.context, name);
    }
};

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
    apps: ?*desktop_entries.Service = null,
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
        /// Every output's shells (a bar, a popup), in stacking order.
        shells: []const *const script.config.SurfaceSpec,
        decoration_surface: ?*const script.config.SurfaceSpec,
        sources: []const script.config.SourceSpec,
        spawner: ?Spawner,
        mark_surfaces: MarkSurfaces,
    ) !river_role_lifecycle.Hooks {
        self.* = .{};
        self.allocator = allocator;
        self.io = io;
        self.clock_origin = std.Io.Clock.awake.now(io);
        if (shells.len == 0) return .{};
        const spec = shells[0];
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
        self.apps = try desktop_entries.Service.init(allocator, io);
        errdefer {
            self.apps.?.deinit();
            self.apps = null;
        }
        try runtime.setSurfaceHooks(self.graphics.?.surfaceHooks());
        self.context = .{
            .allocator = allocator,
            .runtime = runtime,
            .roles = undefined,
            .graphics = self.graphics.?,
            .apps = self.apps.?,
            .spawner = spawner,
            .mark_surfaces = mark_surfaces,
            .source_revisions = try allocator.alloc(u64, self.status.?.sourceCount()),
        };
        self.context.shell_count = @intCast(@min(shells.len, max_output_shells));
        for (shells[0..self.context.shell_count], 0..) |shell, slot| {
            self.context.shell_specs[slot] = shell;
            runtime.shell_placements[slot] = .{
                .bottom = std.mem.eql(u8, shell.edge, "bottom"),
                .width = shell.width,
                .height = shell.height,
                .margin = shell.margin,
            };
        }
        @memset(self.context.source_revisions, std.math.maxInt(u64));
        try self.bindInputSeats(client);
        return self.context.hooks();
    }

    /// Complete the callback context after role storage has a stable address.
    pub fn bindRoles(self: *Bridge, roles: *river_role_lifecycle.Runtime) void {
        if (self.graphics == null) return;
        std.debug.assert(self.context.graphics == self.graphics.?);
        self.context.roles = roles;
        roles.shell_slots = self.context.shell_count;
    }

    pub fn setWake(self: *Bridge, wake: river_presenter_runtime.Wake) void {
        if (self.graphics) |graphics| graphics.setWake(wake);
        if (self.status) |status| status.setWake(.{ .context = wake.context, .run = wake.run });
        if (self.apps) |apps| apps.setWake(.{ .context = wake.context, .run = wake.run });
    }

    pub fn clearWake(self: *Bridge) void {
        if (self.status) |status| status.clearWake();
        if (self.apps) |apps| apps.clearWake();
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
        if (self.apps) |apps| apps.deinit();
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
        if (self.apps) |apps| apps.deinit();
        self.apps = null;
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
    /// The surface that has the pointer.
    target: ?Target = null,
    /// Buttons held down while one of our surfaces has the pointer.
    held: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,

    /// A shell is found by its output when an event is sent: the output keeps
    /// its identity while its shell surface is replaced.
    const Target = union(enum) {
        shell: host.types.ShellSurfaceId,
        decoration: host.types.DecorationId,
    };

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
                    self.leave();
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
                self.target = if (value.surface) |surface| self.targetFor(surface) else null;
                self.x = wayland.client.wl.Fixed.toDouble(value.surface_x);
                self.y = wayland.client.wl.Fixed.toDouble(value.surface_y);
                self.send(.{ .kind = "enter" });
            },
            .leave => {
                self.send(.{ .kind = "leave" });
                self.leave();
            },
            .motion => |value| {
                self.x = wayland.client.wl.Fixed.toDouble(value.surface_x);
                self.y = wayland.client.wl.Fixed.toDouble(value.surface_y);
                self.send(.{ .kind = "motion" });
            },
            .button => |value| {
                self.track(value.state == .pressed);
                self.send(.{
                    .kind = "button",
                    .button = value.button,
                    .pressed = value.state == .pressed,
                });
            },
            .axis => |value| {
                const amount = wayland.client.wl.Fixed.toDouble(value.value);
                self.send(if (value.axis == .vertical_scroll) .{ .kind = "scroll", .dy = amount } else .{ .kind = "scroll", .dx = amount });
            },
            .frame, .axis_source, .axis_stop, .axis_discrete, .axis_value120, .axis_relative_direction => {},
        }
    }

    fn targetFor(self: *const InputSeat, surface: *wayland.client.wl.Surface) ?Target {
        if (self.context.roles.shellForSurface(surface)) |shell| return .{ .shell = shell };
        if (self.context.roles.decorationForSurface(surface)) |decoration| return .{ .decoration = decoration };
        return null;
    }

    fn role(self: *const InputSeat) ?river_presenter_runtime.SurfaceRole {
        return switch (self.target orelse return null) {
            .shell => |shell| .{ .shell = shell },
            .decoration => |decoration| .{ .decoration = decoration },
        };
    }

    /// Which surface the buttons went down on, for `pointer-operation`. Once
    /// every button is up, a pointer operation River has not yet taken over
    /// never will be: it ends here.
    fn track(self: *InputSeat, pressed: bool) void {
        if (pressed) {
            self.held += 1;
            self.context.pressed = self.role();
            return;
        }
        self.held -|= 1;
        if (self.held != 0) return;
        self.context.pressed = null;
        self.context.runtime.adapter.releaseReportedPointerOperations();
        self.context.runtime.requestManage();
    }

    /// The pointer left our surfaces, perhaps for a pointer operation River now
    /// drives: buttons are no longer ours to count.
    fn leave(self: *InputSeat) void {
        self.target = null;
        self.held = 0;
        self.context.pressed = null;
    }

    const Event = struct { kind: []const u8, button: u32 = 0, pressed: bool = false, dx: f64 = 0, dy: f64 = 0 };

    fn send(self: *InputSeat, event: Event) void {
        const target = self.role() orelse return;
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
        self.context.graphics.deliver(target, .{ .service = "pointer", .values = &values }, .events) catch |err|
            std.log.warn("pointer event dropped: {s}", .{@errorName(err)});
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    runtime: *river_host_runtime.Runtime,
    roles: *river_role_lifecycle.Runtime,
    graphics: *river_presenter_runtime.Runtime,
    apps: *desktop_entries.Service,
    spawner: ?Spawner,
    mark_surfaces: MarkSurfaces = .{},
    frame_ms: f64 = 0,
    /// Every output's shells, by shell surface id: the output, and which of
    /// its shells (`shell_specs`) it is.
    shells: std.AutoHashMapUnmanaged(u64, Shell) = .empty,
    shell_specs: [max_output_shells]*const script.config.SurfaceSpec = undefined,
    shell_count: u8 = 0,
    /// The surface a pointer button is held down on, if any.
    pressed: ?river_presenter_runtime.SurfaceRole = null,
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
        apps: u64,
        focused_output: ?wm.OutputId,
    };

    const Shell = struct { output: host.types.OutputId, slot: u8 };

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
            .mark_created = onMarkCreated,
            .mark_retire = onMarkRetire,
        };
    }

    /// An action a surface program asked for:
    /// - `layout <name> args...` runs a layout action on the surface's output
    ///   (a decoration's is its window's).
    /// - `pointer-operation <name> args...`, from a decoration while a pointer
    ///   button is held on it, hands the pointer to River until the buttons
    ///   are released. Its window does not move; the layout action `<name>`
    ///   is told of the motion instead, as `<name> <window> <dx> <dy>
    ///   move|drop|cancel args...` (the right button cancels).
    /// - `spawn argv...` starts a program.
    /// Others are ignored.
    fn perform(self: *Context, role: river_presenter_runtime.SurfaceRole, action: host.surface_composition.Action) void {
        const args = action.args;
        if (std.mem.eql(u8, action.name, "layout")) {
            if (args.len == 0) return;
            const wm_output = self.outputForRole(role) orelse return;
            var rest: [script.layout_projection.max_action_args][]const u8 = undefined;
            const count = @min(args.len - 1, rest.len);
            for (args[1 .. 1 + count], 0..) |arg, index| rest[index] = arg;
            self.runtime.queueLayoutAction(wm_output, args[0], rest[0..count]) catch |err|
                std.log.warn("surface layout action '{s}' failed: {s}", .{ args[0], @errorName(err) });
        } else if (std.mem.eql(u8, action.name, "pointer-operation")) {
            if (args.len == 0) return;
            const decoration = switch (role) {
                .decoration => |id| id,
                .shell => return,
            };
            // Only while the press that asked for it is still down: after the
            // release, River would wait for one that never comes.
            const pressed = self.pressed orelse return;
            if (!std.meta.eql(pressed, role)) return;
            const window = self.roles.windowForDecoration(decoration) orelse return;
            self.runtime.adapter.beginReportedPointerOperation(window, args[0], args[1..]) catch |err| {
                std.log.warn("surface pointer operation '{s}' failed: {s}", .{ args[0], @errorName(err) });
                return;
            };
            self.runtime.requestManage();
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

    fn outputForRole(self: *const Context, role: river_presenter_runtime.SurfaceRole) ?wm.OutputId {
        switch (role) {
            .shell => |shell| {
                const output = self.outputForShell(shell) orelse return null;
                return self.runtime.adapter.objects.wmOutputId(output) catch null;
            },
            .decoration => |decoration| {
                const window = self.roles.windowForDecoration(decoration) orelse return null;
                const wm_window = self.runtime.adapter.objects.wmWindowId(window) catch return null;
                return self.runtime.adapter.worldView().windowOutput(wm_window);
            },
        }
    }

    fn outputForShell(self: *const Context, shell: host.types.ShellSurfaceId) ?host.types.OutputId {
        return (self.shells.get(shell.value) orelse return null).output;
    }

    fn currentDesktopKey(self: *Context) DesktopKey {
        const world = self.runtime.adapter.worldView();
        return .{
            .manage_revision = self.runtime.adapter.revision,
            .epoch = world.epoch(),
            .metadata = self.runtime.adapter.objects.metadata_revision,
            .apps = self.apps.resolvedCount(),
            .focused_output = world.focusedOutput(),
        };
    }

    fn refreshDesktop(self: *Context) !void {
        const key = self.currentDesktopKey();
        var iterator = self.shells.iterator();
        while (iterator.next()) |entry| {
            const shell = host.types.ShellSurfaceId{ .value = entry.key_ptr.* };
            if (self.desktop_keys.get(shell.value)) |sent| if (std.meta.eql(sent, key)) continue;
            try self.sendDesktop(entry.value_ptr.output, shell);
            try self.desktop_keys.put(self.allocator, shell.value, key);
        }
    }

    /// The `desktop` service for one output's shell:
    ///   tag      the active tag's ordinal (1-based)
    ///   tags     per tag: { occupied, active }
    ///   focused  whether this output has keyboard focus
    ///   items    the layout's projection, in order: { key (the layout's name
    ///            for what the item stands for), kind, label, detail, focused,
    ///            overlay, window, app_id, name (the application's, from its
    ///            desktop entry), title, icon, action, args }
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
            var app: desktop_entries.AppInfo = .{};
            if (item.window) |window| if (self.runtime.adapter.objects.wm_to_window.get(window)) |live_window| {
                const record = try self.runtime.adapter.objects.windowRecord(live_window);
                app_id = try arena.dupe(u8, record.app_id);
                title = try arena.dupe(u8, record.title);
                app = try self.apps.lookup(arena, record.app_id, record.pid);
            };
            const args = try arena.alloc(Value, item.arg_count);
            for (item.args[0..item.arg_count], args) |*arg, *value| value.* = .{ .string = try arena.dupe(u8, arg.slice()) };
            destination.* = .{ .object = try arena.dupe(Value.Field, &.{
                .{ .key = "key", .value = .{ .string = try arena.dupe(u8, item.key.slice()) } },
                .{ .key = "kind", .value = .{ .string = try arena.dupe(u8, item.style.slice()) } },
                .{ .key = "label", .value = .{ .string = try arena.dupe(u8, item.text.slice()) } },
                .{ .key = "detail", .value = .{ .string = try arena.dupe(u8, item.detail.slice()) } },
                .{ .key = "focused", .value = .{ .boolean = item.focused } },
                .{ .key = "overlay", .value = .{ .boolean = item.overlay } },
                .{ .key = "window", .value = if (item.window) |window| .{ .number = @floatFromInt(window.raw()) } else .nil },
                .{ .key = "app_id", .value = .{ .string = app_id } },
                .{ .key = "name", .value = .{ .string = app.name } },
                .{ .key = "title", .value = .{ .string = title } },
                .{ .key = "icon", .value = .{ .string = app.icon } },
                .{ .key = "action", .value = .{ .string = try arena.dupe(u8, item.action.slice()) } },
                .{ .key = "args", .value = .{ .array = args } },
            }) };
        }

        const fields = [_]Value.Field{
            .{ .key = "tag", .value = .{ .number = @floatFromInt(active + 1) } },
            .{ .key = "tags", .value = .{ .array = tags } },
            .{ .key = "focused", .value = .{ .boolean = world.focusedOutput() == wm_output } },
            .{ .key = "fullscreen", .value = .{ .boolean = self.tagFullscreen(world, output.active_tag) } },
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
            var iterator = self.shells.keyIterator();
            while (iterator.next()) |shell| {
                self.graphics.deliver(.{ .shell = .{ .value = shell.* } }, .{ .service = status.sourceName(index), .values = &values }, .sample) catch |err|
                    std.log.warn("source '{s}' not delivered: {s}", .{ status.sourceName(index), @errorName(err) });
            }
        }
    }

    pub fn updateFrameServices(raw: ?*anyopaque, _: host.types.OutputId, shell_id: host.types.ShellSurfaceId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        try self.graphics.requestFrame(.{ .shell = shell_id }, self.frame_ms);
    }

    /// The `decoration` service: `{ id, title, app_id, name, icon, focused }`, `id`
    /// being the window's, as layout actions name it.
    pub fn updateDecorationServices(raw: ?*anyopaque, window_id: host.types.WindowId, decoration_id: host.types.DecorationId) !void {
        const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        const record = try self.runtime.adapter.objects.windowRecord(window_id);
        const wm_window = record.wm_id orelse return;
        const world = self.runtime.adapter.worldView();
        _ = world.getWindow(wm_window) orelse return error.UnknownWindow;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const app = try self.apps.lookup(arena.allocator(), record.app_id, record.pid);
        const fields = [_]Value.Field{
            .{ .key = "id", .value = .{ .number = @floatFromInt(wm_window.raw()) } },
            .{ .key = "title", .value = .{ .string = record.title } },
            .{ .key = "app_id", .value = .{ .string = record.app_id } },
            .{ .key = "name", .value = .{ .string = app.name } },
            .{ .key = "icon", .value = .{ .string = app.icon } },
            .{ .key = "focused", .value = .{ .boolean = world.focusedWindow() == wm_window } },
        };
        const values = [_]Value{.{ .object = &fields }};
        try self.graphics.update(.{ .decoration = decoration_id }, .{ .service = "decoration", .values = &values });
    }

    /// Whether a window is fullscreen on `maybe_tag`: on its output, the
    /// shells (the bar) then stay out of its way.
    fn tagFullscreen(self: *const Context, world: *const wm.World, maybe_tag: ?wm.TagId) bool {
        const wanted = maybe_tag orelse return false;
        for (self.runtime.adapter.objects.window_order.items) |live_window| {
            const record = self.runtime.adapter.objects.windows.get(live_window) orelse continue;
            const wm_window = record.wm_id orelse continue;
            const window = world.getWindow(wm_window) orelse continue;
            if (window.tag == wanted and window.lifecycle == .managed and window.placement == .fullscreen) return true;
        }
        return false;
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

/// One of an output's shells: sized by its configuration (see
/// `river_host_runtime.ShellPlacement`, which places it), its whole surface
/// taking the pointer unless it is configured not to.
fn onShellCreated(raw: ?*anyopaque, output: host.types.OutputId, slot: u8, shell: *wayland.client.river.ShellSurfaceV1, surface: *wayland.client.wl.Surface) !void {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    if (slot >= self.shell_count) return error.UnknownShellSlot;
    const spec = self.shell_specs[slot];
    const shell_id = try self.roles.adapter.objects.shellSurfaceId(shell);
    const size = (try self.roles.adapter.objects.outputSize(output)) orelse return error.OutputGeometryUnavailable;
    const placement = self.runtime.shell_placements[slot];
    const rect = placement.rect(.{ .x = 0, .y = 0 }, size);
    const role_extent = try Context.extent(rect.width, rect.height);
    try self.graphics.createRoleFor(.{ .shell = shell_id }, surface, role_extent, spec);
    try self.shells.put(self.allocator, shell_id.value, .{ .output = output, .slot = slot });
    self.shells_created +%= 1;
    const input_region = try self.roles.compositor.createRegion();
    defer input_region.destroy();
    if (spec.input) input_region.add(0, 0, @intCast(role_extent.width), @intCast(role_extent.height));
    surface.setInputRegion(input_region);
    std.log.info("River shell surface '{s}' ready (output {d})", .{ spec.name, output.value });
}

fn onShellRetire(raw: ?*anyopaque, output: host.types.OutputId, shell: host.types.ShellSurfaceId) !river_role_lifecycle.RetirementStatus {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    _ = output;
    _ = self.shells.remove(shell.value);
    _ = self.desktop_keys.remove(shell.value);
    return retire(self, .{ .shell = shell });
}

/// A surface drawn on a layout mark: the mark's configured content, sized to
/// the mark. It is only drawn on; the pointer passes through it.
fn onMarkCreated(raw: ?*anyopaque, name: []const u8, shell: host.types.ShellSurfaceId, surface: *wayland.client.wl.Surface, size: host.types.Size) !void {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
    const spec = self.mark_surfaces.get(name) orelse return error.UnknownMarkSurface;
    try self.graphics.createRoleFor(.{ .shell = shell }, surface, try Context.extent(size.width, size.height), spec);
    const input_region = try self.roles.compositor.createRegion();
    defer input_region.destroy();
    surface.setInputRegion(input_region);
}

fn onMarkRetire(raw: ?*anyopaque, shell: host.types.ShellSurfaceId) !river_role_lifecycle.RetirementStatus {
    const self: *Context = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
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
