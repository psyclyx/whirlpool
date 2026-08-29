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
    build: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        *const wm.WorldView,
        wm.OutputId,
        f32,
    ) anyerror!wm.LayoutPlans,
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
};

const Boundary = enum { none, manage, render };
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    adapter: world.Adapter,
    options: Options,
    driver: ?Driver = null,
    manager: ?*live.Manager = null,
    boundary: Boundary = .none,
    callback_depth: u32 = 0,
    frames: ?world.FrameSet = null,
    render: ?world.RenderCycle = null,
    queued_intents: script.IntentBatch,
    config_program: ?*const script.config.Config = null,
    configured_actions: std.ArrayList(usize) = .empty,
    surface_queue: SurfaceQueue,
    shell_requested: bool = false,
    manage_dirty_requested: bool = false,
    manage_request_pending: bool = false,
    render_expected: bool = false,
    stats: Stats = .{},

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

    /// Queue one configured binding action for the next manage cycle.
    pub fn queueConfiguredAction(self: *Runtime, action_index: usize) !void {
        self.assertValid();
        if (self.config_program == null) return error.ConfigNotLoaded;
        if (action_index >= self.config_program.?.bindings.len) return error.InvalidConfiguredAction;
        try self.configured_actions.append(self.allocator, action_index);
        self.manage_dirty_requested = true;
        self.assertValid();
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
        if (self.render) |*cycle| cycle.deinit();
        if (self.frames) |*frames| frames.deinit();
        if (self.options.surfaces) |surface_hooks|
            self.surface_queue.deinit(surface_hooks.context, surface_hooks.discard)
        else
            self.surface_queue.deinit(null, null);
        self.configured_actions.deinit(self.allocator);
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
        }) catch |err| return transport.finishManageError(Runtime, self, err);
        errdefer cycle.deinit();

        var operations = std.ArrayList(types.ManageOperation).empty;
        defer operations.deinit(self.allocator);
        for (cycle.frames.frames()) |frame| try operations.appendSlice(self.allocator, frame.plans.river_manage.operations.items);
        try self.adapter.appendServerDecorationRequests(&operations);
        try self.adapter.appendSeatFocusRequests(&operations);
        try plans.applyManageTransport(transport.manage(Runtime, self), .{ .operations = operations.items });
        self.adapter.commitServerDecorationRequests();
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
        if (self.manager) |manager| {
            manager.placeOutputShellRoles(self, resolveShellPosition);
            manager.placeDecorationRoles(28);
        }
        defer {
            self.render.?.deinit();
            self.render = null;
        }

        var operations = std.ArrayList(types.RenderOperation).empty;
        defer operations.deinit(self.allocator);
        for (frames.frames()) |frame| try operations.appendSlice(self.allocator, frame.plans.river_render.operations.items);
        var commits = std.ArrayList(coordinator.SubmittedCommit).empty;
        defer commits.deinit(self.allocator);
        try self.surface_queue.appendReady(self.allocator, &commits);
        try coordinator.runRender(.{ .operations = operations.items }, commits.items, transport.renderEmitter(Runtime, self));
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

    fn resolveShellPosition(raw: ?*anyopaque, output: *wayland.client.river.OutputV1) ?live.ShellPosition {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return null));
        const id = self.adapter.objects.outputId(output) catch return null;
        const position = (self.adapter.objects.outputs.get(id) orelse return null).position orelse return null;
        return .{ .x = position.x, .y = position.y };
    }

    fn assertValid(self: *const Runtime) void {
        std.debug.assert(self.options.max_intents > 0);
        std.debug.assert(self.options.max_pending_commits > 0);
        std.debug.assert(self.queued_intents.count() <= self.options.max_intents);
        std.debug.assert(self.surface_queue.count() <= self.options.max_pending_commits);
        std.debug.assert(self.config_program != null or self.configured_actions.items.len == 0);
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
        _: ?*anyopaque,
        allocator: std.mem.Allocator,
        snapshot: *const wm.WorldView,
        output_id: wm.OutputId,
        camera_value: f32,
    ) !wm.LayoutPlans {
        const output = snapshot.getOutput(output_id).?;
        const tag = snapshot.getTag(output.active_tag).?;
        const column = snapshot.getColumn(tag.columns.items[0]).?;
        const node = snapshot.getNode(column.root.?).?;
        const window = snapshot.getWindow(node.window.?).?;
        const camera: wm.CameraTarget = .{ .tag = tag.id, .current = camera_value, .target = camera_value, .strip_width = 800 };
        var result: wm.LayoutPlans = .{
            .manage = .{ .context = .{ .allocator = allocator, .epoch = snapshot.epoch(), .output = output_id, .camera = camera } },
            .render = .{ .context = .{ .allocator = allocator, .epoch = snapshot.epoch(), .output = output_id, .camera = camera } },
        };
        errdefer result.deinit();
        const virtual: wm.FRect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
        try result.manage.dimensions.append(allocator, .{ .window = window.id, .column = column.id, .size = .{ .width = 800, .height = 600 }, .virtual = virtual });
        try result.render.entries.append(allocator, .{
            .window = window.id,
            .column = column.id,
            .placement = window.placement,
            .target_virtual = virtual,
            .screen = output.usable,
            .clip = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
            .visible = true,
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
    var trace = TestTrace{ .allocator = std.testing.allocator };
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
    try std.testing.expectEqualSlices(u8, "pmMascrrrrRblk", trace.events.items);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.committed_surfaces);
    try std.testing.expectEqual(@as(u64, 1), runtime.stats.shell_callbacks);

    try runtime.stageRenderBoundary();
    try runtime.afterDispatch();
    try std.testing.expectEqualSlices(u8, "pmMascrrrrRblkrrrrR", trace.events.items);
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
