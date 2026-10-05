//! Deferred River host coordinator.
//!
//! Generated listeners only stage facts and transaction boundaries. Policy,
//! shell callbacks, plan construction, and surface commits run from
//! `afterDispatch`, after the Wayland dispatcher has returned.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");
const live = @import("whirlpool-river-live");
const plans = @import("whirlpool-river-live-plans");
const world = @import("whirlpool-river-live-world");
const configured_actions = @import("actions.zig");
const listeners = @import("listeners.zig");
const policy = @import("policy.zig");
const SurfaceQueue = @import("surface_queue.zig").Queue;
const transport = @import("transport/root.zig");

const types = host.types;
const coordinator = host.river_coordinator;

pub const PolicyHook = struct {
    context: ?*anyopaque = null,
    budget: script.CallbackBudget = .{},
    run: *const fn (?*anyopaque, *script.Callback, *const script.Snapshot, *script.IntentBatch) anyerror!void,
};

pub const LayoutHook = struct {
    context: ?*anyopaque = null,
    action: ?configured_actions.Layout = null,
    project: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        *const wm.WorldView,
        wm.OutputId,
    ) anyerror!?script.LayoutProjection = null,
    build: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        *const wm.WorldView,
        wm.OutputId,
        f64,
    ) anyerror!wm.LayoutPlans,
};

pub const ClockHook = struct {
    context: ?*anyopaque = null,
    monotonic_ms: *const fn (?*anyopaque) f64,
};

pub const ShellHook = struct {
    context: ?*anyopaque = null,
    budget: script.CallbackBudget = .{},
    begin: *const fn (?*anyopaque) anyerror!void,
    run: *const fn (?*anyopaque, *script.Callback) anyerror!void,
    commit: *const fn (?*anyopaque) anyerror!void,
    rollback: *const fn (?*anyopaque) void,
};

/// The retained presenter owns token interpretation and all wl_surface,
/// graphics backend details. `commit` must be allocation-free and cannot
/// fail after the coordinator has sent sync_next_commit.
pub const SurfaceHooks = struct {
    context: ?*anyopaque = null,
    prepare: *const fn (?*anyopaque, coordinator.SubmittedCommit) anyerror!void,
    commit: *const fn (?*anyopaque, coordinator.SubmittedCommit) void,
    discard: *const fn (?*anyopaque, coordinator.SubmittedCommit) void,
};

pub const SeatHook = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, *wayland.client.river.SeatV1) anyerror!void,
};

pub const ManageHook = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque) anyerror!void,
};

pub const SpawnHook = configured_actions.Spawn;

pub const Options = struct {
    policy: ?PolicyHook = null,
    layout: ?LayoutHook = null,
    clock: ?ClockHook = null,
    shell: ?ShellHook = null,
    surfaces: ?SurfaceHooks = null,
    seat: ?SeatHook = null,
    manage: ?ManageHook = null,
    spawn: ?SpawnHook = null,
    max_intents: usize = 256,
    max_pending_commits: usize = 256,
};

/// Compositor-free tests inject this edge. Production uses live_plans.
pub const Driver = struct {
    context: *anyopaque,
    emit_manage: *const fn (*anyopaque, types.ManageOperation) anyerror!void,
    finish_manage: *const fn (*anyopaque) anyerror!void,
    sync_surface: *const fn (*anyopaque, coordinator.SurfaceRole) void,
    emit_render: *const fn (*anyopaque, types.RenderOperation) anyerror!void,
    finish_render: *const fn (*anyopaque) anyerror!void,
    manage_dirty: *const fn (*anyopaque) anyerror!void,
};

pub const Stats = struct {
    policy_callbacks: u64 = 0,
    policy_failures: u64 = 0,
    shell_callbacks: u64 = 0,
    shell_failures: u64 = 0,
    committed_surfaces: u64 = 0,
    discarded_surfaces: u64 = 0,
    /// Rendering operations sent to River, skipped as already true, and how
    /// many render sequences restated everything.
    render_ops_sent: u64 = 0,
    render_ops_skipped: u64 = 0,
    render_full_refreshes: u64 = 0,
};
pub const WindowChrome = struct { decoration_height: i32, border_width: i32 };

const Boundary = enum { none, manage, render };
const PendingLayoutAction = struct {
    output: wm.OutputId,
    name: []u8,
    args: [][]u8,

    pub fn deinit(self: *PendingLayoutAction, allocator: std.mem.Allocator) void {
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        allocator.free(self.name);
        self.* = undefined;
    }
};
/// Shells per output (see `ShellPlacement`).
pub const max_output_shells = live.max_output_shells;

pub const ShellRect = struct { x: i32, y: i32, width: i32, height: i32 };

/// Where one of an output's shells sits: against its top or bottom edge,
/// `margin` from it, `width` wide and centred (0: the output's width),
/// `height` tall (0: the output's height).
pub const ShellPlacement = struct {
    bottom: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    margin: u32 = 0,

    /// Its rectangle on an output at `origin` of `size`.
    pub fn rect(self: ShellPlacement, origin: types.Point, size: types.Size) ShellRect {
        const width: i32 = if (self.width == 0) size.width else @min(size.width, std.math.cast(i32, self.width) orelse size.width);
        const height: i32 = if (self.height == 0) size.height else @min(size.height, std.math.cast(i32, self.height) orelse size.height);
        const margin: i32 = std.math.cast(i32, self.margin) orelse 0;
        return .{
            .x = origin.x + @divTrunc(size.width - width, 2),
            .y = if (self.bottom) origin.y + size.height - height - margin else origin.y + margin,
            .width = width,
            .height = height,
        };
    }
};

test "a shell sits against its edge, centred when narrower than the output" {
    const output_origin = types.Point{ .x = 100, .y = 50 };
    const output_size = types.Size{ .width = 1000, .height = 800 };
    const bar = (ShellPlacement{ .bottom = true, .height = 38 }).rect(output_origin, output_size);
    try std.testing.expectEqual(ShellRect{ .x = 100, .y = 812, .width = 1000, .height = 38 }, bar);
    const popup = (ShellPlacement{ .width = 320, .height = 120, .margin = 80 }).rect(output_origin, output_size);
    try std.testing.expectEqual(ShellRect{ .x = 440, .y = 130, .width = 320, .height = 120 }, popup);
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    adapter: world.Adapter,
    options: Options,
    /// Each of an output's shells' placement, by slot.
    shell_placements: [live.max_output_shells]ShellPlacement = [_]ShellPlacement{.{}} ** live.max_output_shells,
    driver: ?Driver = null,
    manager: ?*live.Manager = null,
    boundary: Boundary = .none,
    callback_depth: u32 = 0,
    frames: ?world.FrameSet = null,
    render: ?world.RenderCycle = null,
    queued_intents: script.IntentBatch,
    config_program: ?*const script.config.Config = null,
    configured_actions: std.ArrayList(usize) = .empty,
    layout_actions: std.ArrayList(PendingLayoutAction) = .empty,
    surface_queue: SurfaceQueue,
    shell_requested: bool = false,
    manage_dirty_requested: bool = false,
    manage_request_pending: bool = false,
    render_expected: bool = false,
    stats: Stats = .{},
    /// What River already holds, so unchanged rendering state is not resent.
    render_delta: host.render_delta.RenderDelta,

    /// Initialize a compositor-free host runtime with default limits.
    pub fn init(allocator: std.mem.Allocator) Runtime {
        return initWithOptions(allocator, .{});
    }

    /// Initialize a host runtime with explicit hooks and resource limits.
    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) Runtime {
        std.debug.assert(options.max_intents > 0);
        std.debug.assert(options.max_pending_commits > 0);
        const runtime = Runtime{
            .allocator = allocator,
            .adapter = world.Adapter.init(allocator, .{}),
            .options = options,
            .queued_intents = script.IntentBatch.init(allocator, options.max_intents),
            .surface_queue = .init(allocator, options.max_pending_commits),
            .render_delta = host.render_delta.RenderDelta.init(allocator),
        };
        runtime.assertValid();
        return runtime;
    }

    /// Install the transport edge used by compositor-free integration tests.
    pub fn setDriver(self: *Runtime, driver: Driver) void {
        self.assertValid();
        std.debug.assert(self.manager == null);
        self.driver = driver;
        self.assertValid();
    }

    /// Borrow an owned configuration for configured-action lookup.
    pub fn setConfig(self: *Runtime, config: *const script.config.Config) !void {
        self.assertValid();
        if (self.config_program != null) return error.ConfigAlreadyLoaded;
        self.config_program = config;
        self.assertValid();
    }

    pub fn reserveBottom(self: *Runtime, height: u32) !void {
        try self.adapter.reserveBottom(height);
    }

    pub fn configureTags(self: *Runtime, names: []const []const u8) !void {
        try self.adapter.configureTags(names);
    }

    /// Borrow the world once and ask the configured layout for its own
    /// structural projection. The host does not interpret that structure.
    pub fn layoutProjection(self: *Runtime, allocator: std.mem.Allocator, output: wm.OutputId) !?script.LayoutProjection {
        const layout = self.options.layout orelse return null;
        const project = layout.project orelse return null;
        var snapshot = self.adapter.worldView().view();
        return project(layout.context, allocator, &snapshot, output);
    }

    /// Queue one configured binding action for the next manage cycle.
    pub fn queueConfiguredAction(self: *Runtime, action_index: usize) !void {
        self.assertValid();
        if (self.config_program == null) return error.ConfigNotLoaded;
        if (action_index >= self.config_program.?.bindings.len) return error.InvalidConfiguredAction;
        try self.configured_actions.append(self.allocator, action_index);
        self.manage_dirty_requested = true;
        self.assertValid();
    }

    /// Queue one opaque controller action for the next transaction boundary.
    pub fn queueLayoutAction(self: *Runtime, output: wm.OutputId, name: []const u8, args: []const []const u8) !void {
        try self.appendLayoutAction(output, name, args);
        self.manage_dirty_requested = true;
    }

    /// Queue a controller action for the transaction boundary already underway.
    pub fn appendLayoutAction(self: *Runtime, output: wm.OutputId, name: []const u8, args: []const []const u8) !void {
        self.assertValid();
        if (self.layout_actions.items.len >= self.options.max_intents) return error.IntentLimitExceeded;
        var owned = PendingLayoutAction{
            .output = output,
            .name = try self.allocator.dupe(u8, name),
            .args = undefined,
        };
        errdefer self.allocator.free(owned.name);
        owned.args = try self.allocator.alloc([]u8, args.len);
        var initialized: usize = 0;
        errdefer {
            for (owned.args[0..initialized]) |arg| self.allocator.free(arg);
            self.allocator.free(owned.args);
        }
        for (args) |arg| {
            owned.args[initialized] = try self.allocator.dupe(u8, arg);
            initialized += 1;
        }
        try self.layout_actions.append(self.allocator, owned);
        self.assertValid();
    }

    /// Ask River for a manage cycle so external protocol state can be updated
    /// at the transaction boundary even when no WM command is queued.
    pub fn requestManage(self: *Runtime) void {
        self.assertValid();
        self.manage_dirty_requested = true;
        self.assertValid();
    }

    /// Start reported pointer operation `action` on the window under the
    /// pointer, the layout action told `args` and then where on the window's
    /// title bar it was taken (as a decoration's `pointer-operation` is).
    pub fn beginPointerOperationUnderPointer(self: *Runtime, action: []const u8, args: []const []const u8) !void {
        const hover = self.adapter.hovered() orelse return;
        const window = self.adapter.objects.wmWindowId(hover.window) catch return;
        const screen = self.windowScreen(window) orelse return;
        const chrome = self.windowChrome(window) orelse return;
        var x_buffer: [16]u8 = undefined;
        var y_buffer: [16]u8 = undefined;
        var all: [8][]const u8 = undefined;
        if (args.len + 2 > all.len) return error.TooManyArguments;
        for (args, 0..) |arg, index| all[index] = arg;
        all[args.len] = try std.fmt.bufPrint(&x_buffer, "{d}", .{hover.pointer.x - screen.x + chrome.border_width});
        all[args.len + 1] = try std.fmt.bufPrint(&y_buffer, "{d}", .{hover.pointer.y - screen.y + chrome.border_width + chrome.decoration_height});
        try self.adapter.beginReportedPointerOperation(hover.window, action, all[0 .. args.len + 2]);
    }

    /// Where `window` is on screen, as last laid out.
    pub fn windowScreen(self: *const Runtime, window: wm.WindowId) ?wm.Rect {
        const frames = &(self.frames orelse return null);
        for (frames.frames()) |frame| for (frame.plans.render.entries.items) |entry| {
            if (entry.window == window) return entry.screen;
        };
        return null;
    }

    pub fn windowChrome(self: *const Runtime, window: wm.WindowId) ?WindowChrome {
        const frames = &(self.frames orelse return null);
        for (frames.frames()) |frame| for (frame.plans.render.entries.items) |entry| {
            if (entry.window != window) continue;
            return .{
                .decoration_height = entry.decoration_height,
                .border_width = if (entry.border) |border| border.width else 0,
            };
        };
        return null;
    }

    /// Install the sole surface-presentation hook owner.
    pub fn setSurfaceHooks(self: *Runtime, hooks_value: SurfaceHooks) !void {
        self.assertValid();
        if (self.options.surfaces != null) return error.SurfaceHooksAlreadySet;
        if (self.surface_queue.count() != 0) return error.SurfaceCommitsStillPending;
        self.options.surfaces = hooks_value;
        self.assertValid();
    }

    /// Install the sole seat callback owner.
    pub fn setSeatHook(self: *Runtime, hook: SeatHook) !void {
        if (self.options.seat != null) return error.SeatHookAlreadySet;
        self.options.seat = hook;
    }

    /// Install the sole post-manage callback owner.
    pub fn setManageHook(self: *Runtime, hook: ManageHook) !void {
        if (self.options.manage != null) return error.ManageHookAlreadySet;
        self.options.manage = hook;
    }

    /// Install the sole configured-process spawning owner.
    pub fn setSpawnHook(self: *Runtime, hook: SpawnHook) !void {
        if (self.options.spawn != null) return error.SpawnHookAlreadySet;
        self.options.spawn = hook;
    }

    /// Remove surface hooks after all submitted commits are resolved.
    pub fn clearSurfaceHooks(self: *Runtime, expected_context: ?*anyopaque) !void {
        self.assertValid();
        const hooks_value = self.options.surfaces orelse return error.SurfaceHooksNotSet;
        if (hooks_value.context != expected_context) return error.WrongSurfaceHooksOwner;
        if (self.surface_queue.count() != 0) return error.SurfaceCommitsStillPending;
        self.options.surfaces = null;
        self.assertValid();
    }

    /// Attach the live River manager used by production transports.
    pub fn attachManager(self: *Runtime, manager: *live.Manager) !void {
        self.assertValid();
        if (self.driver != null) return error.DriverAlreadyAttached;
        if (self.manager != null) return error.ManagerAlreadyAttached;
        self.manager = manager;
        self.assertValid();
    }

    /// Release all queued and staged host state.
    pub fn deinit(self: *Runtime) void {
        self.assertValid();
        self.render_delta.deinit();
        if (self.render) |*cycle| cycle.deinit();
        if (self.frames) |*frames| frames.deinit();
        if (self.options.surfaces) |surface_hooks|
            self.surface_queue.deinit(surface_hooks.context, surface_hooks.discard)
        else
            self.surface_queue.deinit(null, null);
        self.configured_actions.deinit(self.allocator);
        for (self.layout_actions.items) |*action| action.deinit(self.allocator);
        self.layout_actions.deinit(self.allocator);
        self.queued_intents.deinit();
        self.adapter.deinit();
        self.* = undefined;
    }

    /// Return generated-listener hooks that only stage work.
    pub fn hooks() live.Hooks {
        return listeners.hooks(Runtime);
    }

    /// Run afterDispatch through an erased callback context.
    pub fn afterDispatchCallback(raw: ?*anyopaque) anyerror!void {
        try from(raw).afterDispatch();
    }

    /// Drain one protocol boundary and eligible shell work. This is invalid
    /// while any generated listener is active.
    pub fn afterDispatch(self: *Runtime) !void {
        self.assertValid();
        if (self.callback_depth != 0) return error.ProtocolCallbackActive;
        switch (self.boundary) {
            .manage => try self.runManage(),
            .render => try self.runRender(),
            .none => {},
        }
        if (self.boundary == .none) try self.runShell();
        self.discardCancelledSurfaces();
        if (self.manage_dirty_requested and self.boundary == .none) {
            if (!self.manage_request_pending) {
                try self.requestManageDirty();
                self.manage_request_pending = true;
            }
            self.manage_dirty_requested = false;
        }
        self.assertValid();
    }

    /// Queue one semantic intent for the next policy transaction.
    pub fn queueIntent(self: *Runtime, intent: script.Intent) !void {
        self.assertValid();
        try self.queued_intents.append(intent);
        self.manage_dirty_requested = true;
        self.assertValid();
    }

    /// Request one shell callback at the next safe point.
    pub fn requestShellPhase(self: *Runtime) void {
        self.assertValid();
        self.shell_requested = true;
        self.assertValid();
    }

    /// Take ownership of one prepared surface commit.
    pub fn queueSubmittedCommit(self: *Runtime, commit: coordinator.SubmittedCommit) !void {
        try self.surface_queue.enqueue(commit);
        // An asynchronous presenter can become ready while River is idle.
        // Demand a transaction so the queued buffer reaches the sync/commit
        // edge instead of waiting for unrelated window-manager activity.
        if (self.manager != null and !renderAlreadyScheduled(
            self.boundary,
            self.manage_request_pending,
            self.render_expected,
        ))
            self.manage_dirty_requested = true;
    }

    /// Return the number of pending or cancelled surface commits.
    pub fn pendingCommitCount(self: *const Runtime) usize {
        return self.surface_queue.count();
    }

    /// Cancel and discard any not-yet-committed frame for a role before its
    /// presenter starts retirement. This runs only at the post-dispatch safe
    /// point, never from a generated listener.
    pub fn retireSurfaceRole(self: *Runtime, role: coordinator.SurfaceRole) !void {
        if (self.callback_depth != 0) return error.ProtocolCallbackActive;
        self.surface_queue.cancel(role);
        self.discardCancelledSurfaces();
    }

    /// Compositor-free boundary injection for integration tests.
    pub fn stageManageBoundary(self: *Runtime) !void {
        try self.noteBoundary(.manage);
    }

    /// Stage a compositor-free render boundary for integration tests.
    pub fn stageRenderBoundary(self: *Runtime) !void {
        try self.noteBoundary(.render);
    }

    fn runManage(self: *Runtime) !void {
        self.boundary = .none;
        self.manage_request_pending = false;
        if (self.render != null) return transport.finishManageError(Runtime, self, error.RenderCycleStillLive);
        var draft = self.adapter.beginManageDraft() catch |err| return transport.finishManageError(Runtime, self, err);
        defer draft.deinit();
        try policy.run(self, &draft);
        var cycle = self.adapter.finishManage(&draft, .{
            .layout_context = if (self.options.layout) |layout| layout.context else null,
            .build_layout = if (self.options.layout) |layout| layout.build else null,
            .monotonic_ms = if (self.options.clock) |clock| clock.monotonic_ms(clock.context) else 0,
        }) catch |err| return transport.finishManageError(Runtime, self, err);
        errdefer cycle.deinit();

        var operations = std.ArrayList(types.ManageOperation).empty;
        defer operations.deinit(self.allocator);
        for (cycle.frames.frames()) |frame| for (frame.plans.river_manage.operations.items) |operation| switch (operation) {
            .propose_dimensions => |proposal| if (try self.adapter.needsDimensionProposal(proposal))
                try operations.append(self.allocator, operation),
            .set_tiled, .fullscreen => if (self.adapter.needsWindowPlacementRequest(operation))
                try operations.append(self.allocator, operation),
            else => try operations.append(self.allocator, operation),
        };
        try self.adapter.appendServerDecorationRequests(&operations);
        try self.adapter.appendWindowPlacementRequests(&operations);
        try self.adapter.appendCloseRequests(&operations);
        try self.adapter.appendPointerOperationRequests(&operations);
        try self.adapter.appendSeatFocusRequests(&operations);
        try plans.applyManageTransport(transport.manage(Runtime, self), .{ .operations = operations.items });
        for (operations.items) |operation| switch (operation) {
            .propose_dimensions => |proposal| try self.adapter.commitDimensionProposal(proposal),
            else => {},
        };
        self.adapter.commitServerDecorationRequests();
        self.adapter.commitWindowPlacementRequests(operations.items);
        self.adapter.commitCloseRequests(operations.items);
        self.adapter.commitPointerOperationRequests();
        self.adapter.commitSeatFocusRequests();
        // River guarantees at least one render sequence after every completed
        // manage sequence. Remember that credit so asynchronous surface work
        // does not request a redundant manage transaction in the interval.
        self.render_expected = true;

        if (self.frames) |*previous| previous.deinit();
        self.frames = cycle.frames;
        cycle.facts.deinit();
        cycle = undefined;
    }

    fn runRender(self: *Runtime) !void {
        self.boundary = .none;
        self.render_expected = false;
        const frames = &(self.frames orelse return transport.finishRenderError(Runtime, self, error.MissingFrameSet));
        const render_cycle = self.adapter.beginRender(frames) catch |err| return transport.finishRenderError(Runtime, self, err);
        self.render = render_cycle;
        defer {
            self.render.?.deinit();
            self.render = null;
        }

        var operations = std.ArrayList(types.RenderOperation).empty;
        defer operations.deinit(self.allocator);
        for (frames.frames()) |frame| try operations.appendSlice(self.allocator, frame.plans.river_render.operations.items);
        // A window on a tag no output shows is in no output's plan, so nothing
        // else would ever take it off screen. State it here; the delta below
        // makes it a single request when the window first disappears.
        try self.appendHiddenTagWindows(&operations);
        try self.appendMarks(frames, &operations);
        // Send only what River does not already hold (see render_delta.zig).
        var changed = std.ArrayList(types.RenderOperation).empty;
        defer changed.deinit(self.allocator);
        const topology = self.renderTopology();
        const refresh = self.render_delta.refreshDue(topology);
        const filtered = try self.render_delta.filter(operations.items, &changed, topology);
        self.stats.render_ops_sent += filtered.sent;
        self.stats.render_ops_skipped += filtered.skipped;
        if (filtered.full) self.stats.render_full_refreshes += 1;
        var commits = std.ArrayList(coordinator.SubmittedCommit).empty;
        defer commits.deinit(self.allocator);
        try self.surface_queue.appendReady(self.allocator, &commits);
        // Decoration and shell placements are requests made on the manager
        // directly; they follow the same refresh.
        if (self.manager) |manager| {
            manager.placeOutputShellRoles(self, resolveShellPosition, refresh);
            manager.placeDecorationRoles(self, resolveDecorationPosition, refresh);
        }
        coordinator.runRender(.{ .operations = changed.items }, commits.items, transport.renderEmitter(Runtime, self)) catch |err| {
            // Part of the plan may not have reached River: trust nothing.
            self.render_delta.invalidate();
            return err;
        };
        if (render_cycle.dimensions_changed or frames.needs_frame) self.manage_dirty_requested = true;
    }

    fn runShell(self: *Runtime) !void {
        if (!self.shell_requested) return;
        self.shell_requested = false;
        const shell = self.options.shell orelse return;
        shell.begin(shell.context) catch |err| {
            self.stats.shell_failures += 1;
            return err;
        };
        var callback: script.Callback = .{};
        callback.begin(.shell_callback, shell.budget) catch |err| {
            shell.rollback(shell.context);
            return err;
        };
        defer callback.end();
        self.stats.shell_callbacks += 1;
        shell.run(shell.context, &callback) catch |err| {
            self.stats.shell_failures += 1;
            shell.rollback(shell.context);
            return err;
        };
        shell.commit(shell.context) catch |err| {
            self.stats.shell_failures += 1;
            shell.rollback(shell.context);
            return err;
        };
    }

    fn requestManageDirty(self: *Runtime) !void {
        if (self.driver) |driver| return driver.manage_dirty(driver.context);
        const manager = self.manager orelse return error.MissingManager;
        if (manager.state != .claimed) return error.InvalidManagerState;
        manager.proxy.manageDirty();
    }

    fn discardCancelledSurfaces(self: *Runtime) void {
        const surface_hooks = self.options.surfaces orelse return;
        self.stats.discarded_surfaces += self.surface_queue.discardCancelled(surface_hooks.context, surface_hooks.discard);
    }

    fn noteBoundary(self: *Runtime, boundary: Boundary) !void {
        if (self.boundary != .none) return error.BoundaryAlreadyPending;
        self.boundary = boundary;
    }

    fn from(raw: ?*anyopaque) *Runtime {
        return @ptrCast(@alignCast(raw orelse unreachable));
    }

    fn resolveShellPosition(raw: ?*anyopaque, output: *wayland.client.river.OutputV1, slot: u8) ?live.ShellPosition {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return null));
        const id = self.adapter.objects.outputId(output) catch return null;
        const record = self.adapter.objects.outputs.get(id) orelse return null;
        const position = record.position orelse return null;
        const size = record.dimensions orelse return null;
        if (slot >= self.shell_placements.len) return null;
        const rect = self.shell_placements[slot].rect(.{ .x = position.x, .y = position.y }, size);
        return .{ .x = rect.x, .y = rect.y };
    }

    fn resolveDecorationPosition(raw: ?*anyopaque, window: *wayland.client.river.WindowV1) ?live.DecorationPosition {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return null));
        const live_window = self.adapter.objects.maps.windows.idFor(world.live_objects.proxyRef(window)) orelse return null;
        const wm_window = (self.adapter.objects.windows.get(live_window) orelse return null).wm_id orelse return null;
        const chrome = self.windowChrome(wm_window) orelse return null;
        return live.decorationPosition(chrome.decoration_height, chrome.border_width) catch null;
    }

    /// Each layout mark with a surface: its node at the mark, stacked above the
    /// highest window of its output below it. After every frame's own
    /// stacking, which would otherwise move windows past it.
    fn appendMarks(self: *Runtime, frames: *const world.FrameSet, operations: *std.ArrayList(types.RenderOperation)) !void {
        for (frames.frames()) |frame| for (frame.plans.render.marks.items) |mark| {
            const node = self.adapter.markNode(frame.output, mark.name.slice()) orelse continue;
            try operations.append(self.allocator, .{ .set_position = .{ .node = node, .position = .{ .x = mark.rect.x, .y = mark.rect.y } } });
            var below: ?types.NodeId = null;
            var below_z: i32 = std.math.minInt(i32);
            for (frame.plans.render.entries.items) |entry| {
                if (entry.z_index >= mark.z_index or entry.z_index < below_z) continue;
                const window = self.adapter.objects.wm_to_window.get(entry.window) orelse continue;
                below = (self.adapter.objects.windows.get(window) orelse continue).node;
                below_z = entry.z_index;
            }
            try operations.append(self.allocator, if (below) |other|
                .{ .place_above = .{ .node = node, .other = other } }
            else
                .{ .place_bottom = node });
        };
    }

    fn appendHiddenTagWindows(self: *const Runtime, operations: *std.ArrayList(types.RenderOperation)) !void {
        const view = self.adapter.worldView();
        var index: usize = 0;
        while (view.windowAt(index)) |id| : (index += 1) {
            const record = view.getWindow(id) orelse continue;
            if (record.lifecycle != .managed or view.tagShownSomewhere(record.tag)) continue;
            const host_window = self.adapter.objects.wm_to_window.get(id) orelse continue;
            try operations.append(self.allocator, .{ .hide = host_window });
        }
    }

    /// A digest of which windows and outputs exist and where the outputs are.
    /// Any change means River's rendering state may no longer match the cache.
    fn renderTopology(self: *const Runtime) u64 {
        const view = self.adapter.worldView();
        var hasher = std.hash.Wyhash.init(0);
        var index: usize = 0;
        while (view.windowAt(index)) |id| : (index += 1) hasher.update(std.mem.asBytes(&id.raw()));
        index = 0;
        while (view.outputAt(index)) |id| : (index += 1) {
            hasher.update(std.mem.asBytes(&id.raw()));
            if (view.getOutput(id)) |output| {
                hasher.update(std.mem.asBytes(&output.bounds));
                hasher.update(std.mem.asBytes(&output.usable));
                hasher.update(std.mem.asBytes(&output.active_tag.raw()));
            }
        }
        return hasher.final();
    }

    fn assertValid(self: *const Runtime) void {
        std.debug.assert(self.options.max_intents > 0);
        std.debug.assert(self.options.max_pending_commits > 0);
        std.debug.assert(self.queued_intents.count() <= self.options.max_intents);
        std.debug.assert(self.surface_queue.count() <= self.options.max_pending_commits);
        std.debug.assert(self.config_program != null or self.configured_actions.items.len == 0);
        std.debug.assert(self.layout_actions.items.len <= self.options.max_intents);
        std.debug.assert(self.render == null or self.frames != null);
        std.debug.assert(self.driver == null or self.manager == null);
    }
};

fn renderAlreadyScheduled(boundary: Boundary, manage_pending: bool, render_expected: bool) bool {
    return manage_pending or render_expected or boundary == .manage or boundary == .render;
}

test "surface completions reuse staged and promised render transactions" {
    try std.testing.expect(!renderAlreadyScheduled(.none, false, false));
    try std.testing.expect(renderAlreadyScheduled(.none, true, false));
    try std.testing.expect(renderAlreadyScheduled(.manage, false, false));
    try std.testing.expect(renderAlreadyScheduled(.render, false, false));
    try std.testing.expect(renderAlreadyScheduled(.none, false, true));
}

test "hooks defer transaction work to the after-dispatch seam" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const hooks_value = Runtime.hooks();
    try std.testing.expect(hooks_value.defer_transactions);
    try std.testing.expect(hooks_value.on_manage_start != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.adapter.objects.counts().windows);
}

const TestTrace = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(u8) = .empty,
    policy_calls: usize = 0,
    needs_frame: bool = false,

    fn add(self: *@This(), event: u8) !void {
        try self.events.append(self.allocator, event);
    }
    fn from(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }
    fn required(raw: *anyopaque) *@This() {
        return @ptrCast(@alignCast(raw));
    }

    fn policy(raw: ?*anyopaque, callback: *script.Callback, snapshot: *const script.Snapshot, _: *script.IntentBatch) !void {
        const self = from(raw);
        try std.testing.expectEqual(script.SafePoint.wm_policy, callback.phase);
        try callback.step(1);
        try snapshot.validate();
        self.policy_calls += 1;
        try self.add('p');
    }
    fn layout(
        raw: ?*anyopaque,
        allocator: std.mem.Allocator,
        snapshot: *const wm.WorldView,
        output_id: wm.OutputId,
        _: f64,
    ) !wm.LayoutPlans {
        const output = snapshot.getOutput(output_id).?;
        const window = snapshot.getWindow(snapshot.windowAt(0).?).?;
        var result: wm.LayoutPlans = .{
            .manage = .{ .context = .{ .allocator = allocator, .epoch = snapshot.epoch(), .output = output_id } },
            .render = .{ .context = .{ .allocator = allocator, .epoch = snapshot.epoch(), .output = output_id } },
            .needs_frame = from(raw).needs_frame,
        };
        errdefer result.deinit();
        try result.manage.dimensions.append(allocator, .{ .window = window.id, .size = .{ .width = 800, .height = 600 } });
        try result.render.entries.append(allocator, .{
            .window = window.id,
            .screen = output.usable,
            .clip = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
            .visible = true,
            .z_index = 0,
        });
        return result;
    }
    fn shellBegin(raw: ?*anyopaque) !void {
        try from(raw).add('b');
    }
    fn shellRun(raw: ?*anyopaque, callback: *script.Callback) !void {
        try std.testing.expectEqual(script.SafePoint.shell_callback, callback.phase);
        try from(raw).add('l');
    }
    fn shellCommit(raw: ?*anyopaque) !void {
        try from(raw).add('k');
    }
    fn shellRollback(_: ?*anyopaque) void {}
    fn prepare(raw: ?*anyopaque, _: coordinator.SubmittedCommit) !void {
        try from(raw).add('a');
    }
    fn commit(raw: ?*anyopaque, _: coordinator.SubmittedCommit) void {
        from(raw).add('c') catch unreachable;
    }
    fn discard(raw: ?*anyopaque, _: coordinator.SubmittedCommit) void {
        from(raw).add('x') catch unreachable;
    }
    fn manage(raw: *anyopaque, _: types.ManageOperation) !void {
        try required(raw).add('m');
    }
    fn finishManage(raw: *anyopaque) !void {
        try required(raw).add('M');
    }
    fn sync(raw: *anyopaque, _: coordinator.SurfaceRole) void {
        required(raw).add('s') catch unreachable;
    }
    fn render(raw: *anyopaque, _: types.RenderOperation) !void {
        try required(raw).add('r');
    }
    fn finishRender(raw: *anyopaque) !void {
        try required(raw).add('R');
    }
    fn dirty(raw: *anyopaque) !void {
        try required(raw).add('d');
    }
};

fn fakeRef(value: usize) types.ProxyRef {
    return types.ProxyRef.init(value) catch unreachable;
}

test "compositor-free coordinator runs policy and retained commits only after boundaries" {
    var trace = TestTrace{ .allocator = std.testing.allocator, .needs_frame = true };
    defer trace.events.deinit(trace.allocator);
    var runtime = Runtime.initWithOptions(std.testing.allocator, .{
        .policy = .{ .context = &trace, .run = TestTrace.policy },
        .layout = .{ .context = &trace, .build = TestTrace.layout },
        .shell = .{ .context = &trace, .begin = TestTrace.shellBegin, .run = TestTrace.shellRun, .commit = TestTrace.shellCommit, .rollback = TestTrace.shellRollback },
        .surfaces = .{ .context = &trace, .prepare = TestTrace.prepare, .commit = TestTrace.commit, .discard = TestTrace.discard },
    });
    defer runtime.deinit();
    runtime.setDriver(.{
        .context = &trace,
        .emit_manage = TestTrace.manage,
        .finish_manage = TestTrace.finishManage,
        .sync_surface = TestTrace.sync,
        .emit_render = TestTrace.render,
        .finish_render = TestTrace.finishRender,
        .manage_dirty = TestTrace.dirty,
    });

    const output = try runtime.adapter.objects.bindOutput(fakeRef(0x1000));
    try runtime.adapter.stageManageFact(.{ .output_position = .{ .output = output, .position = .{ .x = 0, .y = 0 } } });
    try runtime.adapter.stageManageFact(.{ .output_dimensions = .{ .output = output, .size = .{ .width = 800, .height = 600 } } });
    _ = try runtime.adapter.objects.bindWindow(fakeRef(0x2000), fakeRef(0x2001));
    const decoration = try runtime.adapter.objects.bindDecoration(fakeRef(0x3000));

    try runtime.stageManageBoundary();
    try std.testing.expectEqual(@as(usize, 0), trace.policy_calls);
    try runtime.afterDispatch();
    try std.testing.expectEqual(@as(usize, 1), trace.policy_calls);
    try std.testing.expectEqualSlices(u8, "pmM", trace.events.items);

    try runtime.queueSubmittedCommit(.{ .role = .{ .decoration = decoration }, .generation = 1, .token = 9 });
    runtime.requestShellPhase();
    try runtime.stageRenderBoundary();
    try runtime.afterDispatch();
    try std.testing.expectEqualSlices(u8, "pmMascrrrrrRblkd", trace.events.items);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.committed_surfaces);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.shell_callbacks);

    try runtime.stageRenderBoundary();
    try runtime.afterDispatch();
    // The same five rendering operations are already true in River, so the second
    // render sequence sends none of them (it still finishes).
    try std.testing.expectEqualSlices(u8, "pmMascrrrrrRblkdR", trace.events.items);
    try std.testing.expectEqual(@as(u64, 5), runtime.stats.render_ops_sent);
    try std.testing.expectEqual(@as(u64, 5), runtime.stats.render_ops_skipped);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.render_full_refreshes);
}

test "surface retirement discards queued work before presenter teardown" {
    var trace = TestTrace{ .allocator = std.testing.allocator };
    defer trace.events.deinit(trace.allocator);
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setSurfaceHooks(.{
        .context = &trace,
        .prepare = TestTrace.prepare,
        .commit = TestTrace.commit,
        .discard = TestTrace.discard,
    });

    const role = coordinator.SurfaceRole{ .decoration = types.DecorationId.init(17) };
    try runtime.queueSubmittedCommit(.{ .role = role, .generation = 1, .token = 2 });
    try std.testing.expectEqual(@as(usize, 1), runtime.pendingCommitCount());
    try runtime.retireSurfaceRole(role);
    try std.testing.expectEqual(@as(usize, 0), runtime.pendingCommitCount());
    try std.testing.expectEqualSlices(u8, "x", trace.events.items);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.discarded_surfaces);

    try runtime.clearSurfaceHooks(&trace);
}
