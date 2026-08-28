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
const configured_actions = @import("runtime/actions.zig");
const listeners = @import("runtime/listeners.zig");
const SurfaceQueue = @import("runtime/surface_queue.zig").Queue;

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
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) Runtime {
        return .{
            .allocator = allocator,
            .adapter = world.Adapter.init(allocator, .{}),
            .options = options,
            .queued_intents = script.IntentBatch.init(allocator, options.max_intents),
            .surface_queue = .init(allocator, options.max_pending_commits),
        };
    }

    pub fn setDriver(self: *Runtime, driver: Driver) void {
        self.driver = driver;
    }

    pub fn setConfig(self: *Runtime, config: *const script.config.Config) !void {
        self.config_program = config;
    }

    pub fn queueConfiguredAction(self: *Runtime, action_index: usize) !void {
        if (self.config_program == null) return error.ConfigNotLoaded;
        if (action_index >= self.config_program.?.bindings.len) return error.InvalidConfiguredAction;
        try self.configured_actions.append(self.allocator, action_index);
        self.manage_dirty_requested = true;
    }

    pub fn setSurfaceHooks(self: *Runtime, hooks_value: SurfaceHooks) !void {
        if (self.options.surfaces != null) return error.SurfaceHooksAlreadySet;
        if (self.surface_queue.count() != 0) return error.SurfaceCommitsStillPending;
        self.options.surfaces = hooks_value;
    }

    pub fn setSeatHook(self: *Runtime, hook: SeatHook) !void {
        if (self.options.seat != null) return error.SeatHookAlreadySet;
        self.options.seat = hook;
    }

    pub fn setManageHook(self: *Runtime, hook: ManageHook) !void {
        if (self.options.manage != null) return error.ManageHookAlreadySet;
        self.options.manage = hook;
    }

    pub fn setSpawnHook(self: *Runtime, hook: SpawnHook) !void {
        if (self.options.spawn != null) return error.SpawnHookAlreadySet;
        self.options.spawn = hook;
    }

    pub fn clearSurfaceHooks(self: *Runtime, expected_context: ?*anyopaque) !void {
        const hooks_value = self.options.surfaces orelse return error.SurfaceHooksNotSet;
        if (hooks_value.context != expected_context) return error.WrongSurfaceHooksOwner;
        if (self.surface_queue.count() != 0) return error.SurfaceCommitsStillPending;
        self.options.surfaces = null;
    }

    pub fn attachManager(self: *Runtime, manager: *live.Manager) !void {
        if (self.manager != null) return error.ManagerAlreadyAttached;
        self.manager = manager;
    }

    pub fn deinit(self: *Runtime) void {
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

    pub fn hooks() live.Hooks {
        return listeners.hooks(Runtime);
    }

    pub fn afterDispatchCallback(raw: ?*anyopaque) anyerror!void {
        try from(raw).afterDispatch();
    }

    /// Drain one protocol boundary and eligible shell work. This is invalid
    /// while any generated listener is active.
    pub fn afterDispatch(self: *Runtime) !void {
        if (self.callback_depth != 0) return error.ProtocolCallbackActive;
        switch (self.boundary) {
            .manage => try self.runManage(),
            .render => try self.runRender(),
            .none => {},
        }
        if (self.boundary == .none) try self.runShell();
        self.discardCancelledSurfaces();
        if (self.manage_dirty_requested and self.boundary == .none) {
            try self.requestManageDirty();
            self.manage_dirty_requested = false;
        }
    }

    pub fn queueIntent(self: *Runtime, intent: script.Intent) !void {
        try self.queued_intents.append(intent);
        self.manage_dirty_requested = true;
    }

    pub fn requestShellPhase(self: *Runtime) void {
        self.shell_requested = true;
    }

    pub fn queueSubmittedCommit(self: *Runtime, commit: coordinator.SubmittedCommit) !void {
        try self.surface_queue.enqueue(commit);
    }

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
    pub fn stageRenderBoundary(self: *Runtime) !void {
        try self.noteBoundary(.render);
    }

    fn runManage(self: *Runtime) !void {
        self.boundary = .none;
        if (self.render != null) return self.finishManageError(error.RenderCycleStillLive);
        var draft = self.adapter.beginManageDraft() catch |err| return self.finishManageError(err);
        defer draft.deinit();
        try self.consumeInputIntents();
        try self.runPolicy(&draft);
        var cycle = self.adapter.finishManage(&draft, .{
            .layout_context = if (self.options.layout) |layout| layout.context else null,
            .build_layout = if (self.options.layout) |layout| layout.build else null,
        }) catch |err| return self.finishManageError(err);
        errdefer cycle.deinit();

        var operations = std.ArrayList(types.ManageOperation).empty;
        defer operations.deinit(self.allocator);
        for (cycle.frames.frames()) |frame| try operations.appendSlice(self.allocator, frame.plans.river_manage.operations.items);
        try plans.applyManageTransport(self.manageTransport(), .{ .operations = operations.items });

        if (self.frames) |*previous| previous.deinit();
        self.frames = cycle.frames;
        cycle.facts.deinit();
        cycle = undefined;
    }

    fn runPolicy(self: *Runtime, draft: *const world.ManageDraft) !void {
        var policy_intents = script.IntentBatch.init(self.allocator, self.options.max_intents);
        defer policy_intents.deinit();
        if (self.options.policy != null or self.configured_actions.items.len != 0) {
            var snapshot = self.adapter.worldView().view();
            if (self.configured_actions.items.len != 0)
                try configured_actions.append(self.config_program.?, self.configured_actions.items, &snapshot, &policy_intents, self.options.spawn);
            self.configured_actions.clearRetainingCapacity();
            if (self.options.policy) |policy| {
                var callback: script.Callback = .{};
                try callback.begin(.wm_policy, policy.budget);
                defer callback.end();
                self.stats.policy_callbacks += 1;
                policy.run(policy.context, &callback, &snapshot, &policy_intents) catch {
                    self.stats.policy_failures += 1;
                    policy_intents.clear();
                };
            }
        }

        const total = self.queued_intents.count() + policy_intents.count();
        if (total == 0) return;
        if (total > self.options.max_intents) {
            self.stats.policy_failures += 1;
            self.queued_intents.clear();
            return;
        }
        const commands = try self.allocator.alloc(wm.Command, total);
        defer self.allocator.free(commands);
        const queued_count = try self.queued_intents.translate(commands);
        _ = try policy_intents.translate(commands[queued_count..]);
        _ = self.adapter.applyPolicyCommands(draft, commands) catch {
            self.stats.policy_failures += 1;
            self.queued_intents.clear();
            return;
        };
        self.queued_intents.clear();
    }

    fn consumeInputIntents(self: *Runtime) !void {
        const intents = try self.adapter.takeInputIntents();
        defer self.allocator.free(intents);
        for (intents) |intent| {
            const translated = try self.translateInputIntent(intent) orelse continue;
            self.queued_intents.append(translated) catch |err| {
                self.queued_intents.clear();
                return err;
            };
        }
    }

    fn translateInputIntent(self: *Runtime, intent: world.input_intents.Intent) !?script.Intent {
        const live_window = intent.window orelse return null;
        const window = try self.adapter.objects.wmWindowId(live_window);
        const output = (self.adapter.worldView().getWindow(window) orelse return error.UnknownWindow).output orelse return null;
        return switch (intent.action) {
            .focus => .{ .focus_window = window },
            .close => .{ .close_window = window },
            .toggle_floating => .{ .transition_placement = .{ .window = window, .transition = .floating } },
            .toggle_fullscreen => .{ .transition_placement = .{ .window = window, .transition = .fullscreen } },
            .next_column => .{ .focus_direction = .{ .output = output, .direction = .right } },
            .previous_column => .{ .focus_direction = .{ .output = output, .direction = .left } },
            .move, .resize => null,
        };
    }

    fn runRender(self: *Runtime) !void {
        self.boundary = .none;
        const frames = &(self.frames orelse return self.finishRenderError(error.MissingFrameSet));
        const render_cycle = self.adapter.beginRender(frames) catch |err| return self.finishRenderError(err);
        self.render = render_cycle;
        if (self.manager) |manager| manager.placeOutputShellRoles();
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
        try coordinator.runRender(.{ .operations = operations.items }, commits.items, self.renderEmitter());
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

    fn manageTransport(self: *Runtime) plans.Transport {
        if (self.driver != null) return .{
            .phase = .managing,
            .context = @ptrCast(self),
            .resolver = null,
            .emit_manage = driverManage,
            .emit_render = driverRenderUnused,
            .finish_manage = driverFinishManage,
            .finish_render = driverFinishRender,
        };
        return plans.liveTransport(self.manager orelse unreachable, self.planResolver(), .managing);
    }

    fn renderEmitter(self: *Runtime) coordinator.Emitter {
        return .{ .context = self, .prepare_surface = prepareSurface, .sync_surface = syncSurface, .commit_surface = commitSurface, .render_operation = renderOperation, .finish_render = finishRender };
    }

    fn finishManageError(self: *Runtime, source: anyerror) anyerror {
        plans.applyManageTransport(self.manageTransport(), .{ .operations = &.{} }) catch |finish_err| return finish_err;
        return source;
    }
    fn finishRenderError(self: *Runtime, source: anyerror) anyerror {
        coordinator.runRender(.{ .operations = &.{} }, &.{}, self.renderEmitter()) catch |finish_err| return finish_err;
        return source;
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

    fn planResolver(self: *Runtime) plans.Resolver {
        return .{ .context = self, .window = resolveWindow, .node = resolveNode, .seat = resolveSeat, .output = resolveOutput, .shell_surface = resolveShellSurface, .decoration = resolveDecoration, .pointer_binding = resolvePointerBinding };
    }

    fn from(raw: ?*anyopaque) *Runtime {
        return @ptrCast(@alignCast(raw orelse unreachable));
    }
    fn fromRequired(raw: *anyopaque) *Runtime {
        return @ptrCast(@alignCast(raw));
    }

    fn resolveWindow(raw: *anyopaque, id: types.WindowId) anyerror!*wayland.client.river.WindowV1 {
        return fromRequired(raw).adapter.objects.windowProxy(id);
    }
    fn resolveNode(raw: *anyopaque, id: types.NodeId) anyerror!*wayland.client.river.NodeV1 {
        return fromRequired(raw).adapter.objects.nodeProxy(id);
    }
    fn resolveSeat(raw: *anyopaque, id: types.SeatId) anyerror!*wayland.client.river.SeatV1 {
        return fromRequired(raw).adapter.objects.seatProxy(id);
    }
    fn resolveOutput(raw: *anyopaque, id: types.OutputId) anyerror!*wayland.client.river.OutputV1 {
        return fromRequired(raw).adapter.objects.outputProxy(id);
    }
    fn resolveShellSurface(raw: *anyopaque, id: types.ShellSurfaceId) anyerror!*wayland.client.river.ShellSurfaceV1 {
        return fromRequired(raw).adapter.objects.shellSurfaceProxy(id);
    }
    fn resolveDecoration(raw: *anyopaque, id: types.DecorationId) anyerror!*wayland.client.river.DecorationV1 {
        return fromRequired(raw).adapter.objects.decorationProxy(id);
    }
    fn resolvePointerBinding(raw: *anyopaque, id: types.PointerBindingId) anyerror!*wayland.client.river.PointerBindingV1 {
        return fromRequired(raw).adapter.objects.pointerBindingProxy(id);
    }

    fn driverManage(raw: *anyopaque, _: ?*const plans.Resolver, operation: types.ManageOperation) anyerror!void {
        const self = fromRequired(raw);
        const driver = self.driver.?;
        return driver.emit_manage(driver.context, operation);
    }
    fn driverRenderUnused(_: *anyopaque, _: ?*const plans.Resolver, _: types.RenderOperation) anyerror!void {
        return error.InvalidSequencePhase;
    }
    fn driverFinishManage(raw: *anyopaque) anyerror!void {
        const self = fromRequired(raw);
        const driver = self.driver.?;
        return driver.finish_manage(driver.context);
    }
    fn driverFinishRender(raw: *anyopaque) anyerror!void {
        const self = fromRequired(raw);
        const driver = self.driver.?;
        return driver.finish_render(driver.context);
    }

    fn prepareSurface(raw: ?*anyopaque, commit: coordinator.SubmittedCommit) anyerror!void {
        const self = from(raw);
        // Resolve every live role before the first sync/commit request. The
        // manager cannot mutate these maps during this post-dispatch phase.
        if (self.driver == null) switch (commit.role) {
            .shell => |id| _ = try self.adapter.objects.shellSurfaceProxy(id),
            .decoration => |id| _ = try self.adapter.objects.decorationProxy(id),
        };
        const surface_hooks = self.options.surfaces orelse return error.MissingSurfacePresenter;
        return surface_hooks.prepare(surface_hooks.context, commit);
    }
    fn syncSurface(raw: ?*anyopaque, role: coordinator.SurfaceRole) void {
        const self = from(raw);
        if (self.driver) |driver| return driver.sync_surface(driver.context, role);
        switch (role) {
            .shell => |id| (self.adapter.objects.shellSurfaceProxy(id) catch unreachable).syncNextCommit(),
            .decoration => |id| (self.adapter.objects.decorationProxy(id) catch unreachable).syncNextCommit(),
        }
    }
    fn commitSurface(raw: ?*anyopaque, commit: coordinator.SubmittedCommit) void {
        const self = from(raw);
        const surface_hooks = self.options.surfaces.?;
        surface_hooks.commit(surface_hooks.context, commit);
        std.debug.assert(self.surface_queue.complete(commit));
        self.stats.committed_surfaces += 1;
    }
    fn renderOperation(raw: ?*anyopaque, operation: types.RenderOperation) anyerror!void {
        const self = from(raw);
        if (self.driver) |driver| return driver.emit_render(driver.context, operation);
        var transport = plans.liveTransport(self.manager.?, self.planResolver(), .rendering);
        return transport.emit_render(transport.context, &transport.resolver.?, operation);
    }
    fn finishRender(raw: ?*anyopaque) anyerror!void {
        const self = from(raw);
        if (self.driver) |driver| return driver.finish_render(driver.context);
        return self.manager.?.renderFinish();
    }
};

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
