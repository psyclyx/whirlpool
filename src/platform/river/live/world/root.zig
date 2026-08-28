//! River v5 event staging joined to the authoritative WM world.
//!
//! This is a platform host adapter, not policy and not a Wayland object owner.
//! The owner of the generated proxies forwards child creation and events here;
//! this type gives those callback-lifetime values stable host identities, owns
//! staged fact payloads, reconciles mandatory lifecycle state at manage_start,
//! and builds every output plan from one immutable WM epoch.
//!
//! `live.Manager` currently installs its child listeners internally and only
//! exposes context-free manage/render hooks.  That API cannot carry an
//! instance of this adapter.  The narrow integration contract is therefore the
//! public `bindLive*`, `on*Event`, `beginManage`, and `beginRender` methods
//! below.  A manager owner must forward events to them before destroying closed
//! child proxies.  No UI, Lua, or graphics type crosses this boundary.

const std = @import("std");
const host = @import("whirlpool-host");
const wm = @import("whirlpool-wm");

const types = host.types;
const staged_facts = host.staged_facts;
const composition = host.composition;
const wm_bridge = host.wm_bridge;
pub const input_intents = @import("input.zig");
pub const live_objects = @import("objects.zig");
pub const events = @import("events.zig");
const reconcile = @import("reconcile.zig");

pub const Error = error{
    AdapterPoisoned,
    DuplicateObject,
    IdExhausted,
    IncompleteOutput,
    InvalidDimensions,
    MissingMenuSeat,
    NullProtocolObject,
    StaleManageCycle,
    UnknownDecoration,
    UnknownNode,
    UnknownOutput,
    UnknownPointerBinding,
    UnknownSeat,
    UnknownShellSurface,
    UnknownWindow,
};

/// River's show_window_menu_requested event does not carry a seat while the
/// canonical host fact does.  Applications which implement a window menu must
/// supply an explicit resolver (normally from their input-focus state).  A
/// null resolver deliberately ignores that optional policy event.
pub const MenuSeatResolver = struct {
    context: ?*anyopaque = null,
    resolve: *const fn (?*anyopaque, types.WindowId, types.Point) anyerror!?types.SeatId,
};

pub const Options = struct {
    menu_seat: ?MenuSeatResolver = null,
    input_intent_limit: usize = 256,
};

pub const PlanConfig = struct {
    layout_context: ?*anyopaque = null,
    build_layout: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        *const wm.WorldView,
        wm.OutputId,
        f32,
    ) anyerror!wm.LayoutPlans = null,
    camera_context: ?*anyopaque = null,
    sample_camera: ?*const fn (?*anyopaque, types.OutputId, wm.OutputId) anyerror!f32 = null,
};

/// Result of decoding one generated manager event.  Child creation is kept as
/// an explicit action because the manager owner must obtain each window's node
/// exactly once and decide proxy ownership before calling `bindLiveWindow`.
pub const OutputFrame = struct {
    output: types.OutputId,
    plans: composition.FramePlans,
};

/// All entries are built while the adapter's world is immutable.  `epoch` is
/// therefore shared by every manage and render plan in the set, including a
/// multi-output set.
pub const FrameSet = struct {
    allocator: std.mem.Allocator,
    revision: u64,
    epoch: u64,
    items: []OutputFrame,

    pub fn deinit(self: *FrameSet) void {
        for (self.items) |*item| item.plans.deinit();
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn frames(self: *const FrameSet) []const OutputFrame {
        return self.items;
    }
};

/// The facts and plans for one manage_start are deliberately one owned value:
/// policy/diagnostics can inspect the exact frozen facts whose reconciled world
/// produced the plans, and the render half cannot drift to another epoch.
pub const ManageCycle = struct {
    revision: u64,
    epoch: u64,
    facts: staged_facts.ManageBatch,
    frames: FrameSet,

    pub fn deinit(self: *ManageCycle) void {
        self.frames.deinit();
        self.facts.deinit();
        self.* = undefined;
    }
};

/// Reconciled manage_start state before policy and plan construction. The
/// host may open one immutable script snapshot, apply one atomic semantic
/// command batch, then consume this draft with `finishManage`.
pub const ManageDraft = struct {
    revision: u64,
    facts: ?staged_facts.ManageBatch,

    pub fn deinit(self: *ManageDraft) void {
        if (self.facts) |*facts| facts.deinit();
        self.* = undefined;
    }
};

pub const RenderCycle = struct {
    revision: u64,
    epoch: u64,
    facts: staged_facts.RenderBatch,

    pub fn deinit(self: *RenderCycle) void {
        self.facts.deinit();
        self.* = undefined;
    }
};

pub const LayerFocus = live_objects.LayerFocus;
pub const ObjectCounts = live_objects.Counts;

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    options: Options,
    world: wm.World,
    staged: staged_facts.StagedFacts,
    objects: live_objects.Registry,
    input_queue: input_intents.Queue,
    pointer_actions: std.AutoHashMap(types.PointerBindingId, input_intents.NamedAction),

    revision: u64 = 0,
    poisoned: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) Adapter {
        return .{
            .allocator = allocator,
            .options = options,
            .world = .init(allocator),
            .staged = .init(allocator),
            .objects = .init(allocator),
            .input_queue = .init(allocator, options.input_intent_limit),
            .pointer_actions = .init(allocator),
        };
    }

    /// This releases host storage only.  Generated proxy ownership remains
    /// with the manager/surface-role owner, so disconnect teardown never sends
    /// accidental Wayland requests through this adapter.
    pub fn deinit(self: *Adapter) void {
        self.pointer_actions.deinit();
        self.input_queue.deinit();
        self.objects.deinit();
        self.staged.deinit();
        self.world.deinit();
        self.* = undefined;
    }

    pub fn worldView(self: *const Adapter) *const wm.World {
        return &self.world;
    }

    pub fn configureTags(self: *Adapter, names: []const []const u8) !void {
        if (self.world.liveTagCount() != 0) return error.TagsAlreadyConfigured;
        for (names) |name| _ = try self.world.createNamedTag(name);
    }

    pub fn takeInputIntents(self: *Adapter) ![]input_intents.Intent {
        try self.requireHealthy();
        return self.input_queue.take();
    }

    pub fn bindPointerAction(self: *Adapter, binding: types.PointerBindingId, action: input_intents.NamedAction) !void {
        try self.requireHealthy();
        if (self.objects.maps.pointer_bindings.proxyFor(binding) == null) return error.UnknownPointerBinding;
        try self.pointer_actions.put(binding, action);
    }

    pub fn stageDecorationInput(self: *Adapter, decoration: types.DecorationId, seat: ?types.SeatId, window: ?types.WindowId, position: ?types.Point, action: input_intents.NamedAction) !void {
        try self.requireHealthy();
        if (self.objects.maps.decorations.proxyFor(decoration) == null) return error.UnknownDecoration;
        if (seat) |value| if (!self.objects.seats.contains(value)) return error.UnknownSeat;
        if (window) |value| if (!self.objects.windows.contains(value)) return error.UnknownWindow;
        try self.input_queue.append(.{ .action = action, .source = .{ .decoration = decoration }, .seat = seat, .window = window, .position = position });
    }

    pub fn visibleTiledDecorationSelection(self: *const Adapter) !host.decoration_selection.SelectionSet {
        return host.decoration_selection.SelectionSet.fromWorld(self.allocator, &self.world, self.objects.output_order.items, @ptrCast(@constCast(self)), resolveSelectionOutput, resolveSelectionWindow);
    }

    pub fn isPoisoned(self: *const Adapter) bool {
        return self.poisoned;
    }

    pub fn stageManageFact(self: *Adapter, fact: types.ManageFact) !void {
        try self.requireHealthy();
        try self.validateManageFact(fact);
        try self.staged.stageManage(fact);
    }

    pub fn stageRenderFact(self: *Adapter, fact: types.RenderFact) !void {
        try self.requireHealthy();
        switch (fact) {
            .window_dimensions => |value| {
                if (!self.objects.windows.contains(value.window)) return error.UnknownWindow;
                try validateSize(value.size);
            },
        }
        try self.staged.stageRender(fact);
    }

    pub fn closeWindowRef(self: *Adapter, proxy: types.ProxyRef) !types.WindowId {
        try self.requireHealthy();
        const id = self.objects.maps.windows.idFor(proxy) orelse return error.UnknownWindow;
        const record = self.objects.windows.get(id) orelse return error.UnknownWindow;
        try self.staged.stageManage(.{ .window_closed = id });
        _ = self.objects.maps.windows.unbindProxy(proxy) catch unreachable;
        _ = self.objects.maps.nodes.unbindId(record.node) catch unreachable;
        return id;
    }

    pub fn removeOutputRef(self: *Adapter, proxy: types.ProxyRef) !types.OutputId {
        try self.requireHealthy();
        const id = self.objects.maps.outputs.idFor(proxy) orelse return error.UnknownOutput;
        try self.staged.stageManage(.{ .output_removed = id });
        _ = self.objects.maps.outputs.unbindProxy(proxy) catch unreachable;
        return id;
    }

    pub fn removeSeatRef(self: *Adapter, proxy: types.ProxyRef) !types.SeatId {
        try self.requireHealthy();
        const id = self.objects.maps.seats.idFor(proxy) orelse return error.UnknownSeat;
        try self.staged.stageManage(.{ .seat_removed = id });
        _ = self.objects.maps.seats.unbindProxy(proxy) catch unreachable;
        return id;
    }

    /// Freeze all manage facts, perform mandatory lifecycle reconciliation,
    /// and compose one frame per complete live output.  A reconciliation error
    /// poisons the adapter because the WM API intentionally offers atomic
    /// semantic commands but not an externally clonable lifecycle transaction;
    /// continuing after a partial allocation failure would be dishonest.
    pub fn beginManageDraft(self: *Adapter) !ManageDraft {
        try self.requireHealthy();
        var facts = try self.staged.takeManage();
        errdefer facts.deinit();

        for (facts.facts()) |fact| try self.validateManageFact(fact);
        reconcile.run(self, facts.facts()) catch |err| {
            self.poisoned = true;
            return err;
        };
        self.world.validate() catch |err| {
            self.poisoned = true;
            return err;
        };

        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
        return .{ .revision = self.revision, .facts = facts };
    }

    /// Apply policy only through the WM's atomic semantic command boundary.
    pub fn applyPolicyCommands(self: *Adapter, draft: *const ManageDraft, commands: wm.Batch) !wm.ApplyResult {
        try self.requireHealthy();
        if (draft.facts == null or draft.revision != self.revision) return error.StaleManageCycle;
        return self.world.applyAtomically(commands);
    }

    pub fn finishManage(self: *Adapter, draft: *ManageDraft, config: PlanConfig) !ManageCycle {
        try self.requireHealthy();
        if (draft.facts == null or draft.revision != self.revision) return error.StaleManageCycle;
        try self.world.validate();
        var frames = try self.buildFrames(config, self.revision);
        errdefer frames.deinit();
        const facts = draft.facts.?;
        draft.facts = null;
        return .{
            .revision = self.revision,
            .epoch = frames.epoch,
            .facts = facts,
            .frames = frames,
        };
    }

    pub fn beginManage(self: *Adapter, config: PlanConfig) !ManageCycle {
        var draft = try self.beginManageDraft();
        defer draft.deinit();
        return self.finishManage(&draft, config);
    }

    /// Consume dimensions for one render_start against the latest durable
    /// frame set. River may issue any number of consecutive render sequences
    /// between manage sequences.
    pub fn beginRender(self: *Adapter, frames: *const FrameSet) !RenderCycle {
        try self.requireHealthy();
        if (frames.revision != self.revision or frames.epoch != self.world.epoch())
            return error.StaleManageCycle;

        var facts = try self.staged.takeRender();
        errdefer facts.deinit();
        for (facts.facts()) |fact| switch (fact) {
            .window_dimensions => |value| {
                const record = self.objects.windows.getPtr(value.window) orelse return error.UnknownWindow;
                try validateSize(value.size);
                record.actual_size = value.size;
            },
        };
        return .{ .revision = frames.revision, .epoch = frames.epoch, .facts = facts };
    }

    /// Transport-neutral half of pointer binding forwarding. Generated
    /// listeners call this after decoding an event; tests and alternate
    /// transports can use it without manufacturing a Wayland proxy.
    pub fn stagePointerBindingIntent(self: *Adapter, id: types.PointerBindingId, pressed: bool) !void {
        try self.requireHealthy();
        if (self.objects.maps.pointer_bindings.proxyFor(id) == null) return error.UnknownPointerBinding;
        if (pressed) try self.input_queue.append(.{ .action = self.pointer_actions.get(id) orelse .focus, .source = .{ .pointer_binding = id } });
    }

    fn requireHealthy(self: *const Adapter) !void {
        if (self.poisoned) return error.AdapterPoisoned;
    }

    fn validateManageFact(self: *const Adapter, fact: types.ManageFact) !void {
        switch (fact) {
            .window_closed,
            .window_maximize_requested,
            .window_unmaximize_requested,
            .window_exit_fullscreen_requested,
            .window_minimize_requested,
            => |id| if (!self.objects.windows.contains(id)) return error.UnknownWindow,
            .window_fullscreen_requested => |value| {
                if (!self.objects.windows.contains(value.window)) return error.UnknownWindow;
                if (value.output) |output| if (!self.objects.outputs.contains(output)) return error.UnknownOutput;
            },
            .output_removed => |id| if (!self.objects.outputs.contains(id)) return error.UnknownOutput,
            .output_position => |value| if (!self.objects.outputs.contains(value.output)) return error.UnknownOutput,
            .output_dimensions => |value| {
                if (!self.objects.outputs.contains(value.output)) return error.UnknownOutput;
                try validateSize(value.size);
            },
            .seat_removed => |id| if (!self.objects.seats.contains(id)) return error.UnknownSeat,
            .seat_window_interaction => |value| {
                if (!self.objects.seats.contains(value.seat)) return error.UnknownSeat;
                if (!self.objects.windows.contains(value.window)) return error.UnknownWindow;
            },
        }
    }

    fn buildFrames(self: *Adapter, config: PlanConfig, revision: u64) !FrameSet {
        var items: std.ArrayList(OutputFrame) = .empty;
        errdefer {
            for (items.items) |*item| item.plans.deinit();
            items.deinit(self.allocator);
        }

        const epoch = self.world.epoch();
        const snapshot = self.world.view();
        for (self.objects.output_order.items) |river_output| {
            const output_record = self.objects.outputs.get(river_output) orelse continue;
            const output = output_record.wm_id orelse continue;
            const camera = if (config.sample_camera) |sample|
                try sample(config.camera_context, river_output, output)
            else
                try currentCamera(&self.world, output);
            const build_layout = config.build_layout orelse return error.MissingLayoutProvider;
            const layout_plans = try build_layout(config.layout_context, self.allocator, &snapshot, output, camera);
            var plans = try composition.translateFrame(self.allocator, layout_plans, self.hostResolver());
            errdefer plans.deinit();
            if (plans.epoch != epoch or plans.manage.context.epoch != plans.render.context.epoch)
                return error.PlanEpochMismatch;
            try items.append(self.allocator, .{ .output = river_output, .plans = plans });
        }

        return .{
            .allocator = self.allocator,
            .revision = revision,
            .epoch = epoch,
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn hostResolver(self: *Adapter) wm_bridge.Resolver {
        return .{
            .context = self,
            .window = resolveWindow,
            .output = resolveOutput,
            .node = resolveNode,
        };
    }

    fn resolveWindow(context: ?*anyopaque, id: wm.WindowId) !types.WindowId {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.objects.wm_to_window.get(id) orelse error.UnknownWindow;
    }

    fn resolveOutput(context: ?*anyopaque, id: wm.OutputId) !types.OutputId {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.objects.wm_to_output.get(id) orelse error.UnknownOutput;
    }

    fn resolveNode(context: ?*anyopaque, id: wm.WindowId) !types.NodeId {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        const window = self.objects.wm_to_window.get(id) orelse return error.UnknownWindow;
        return (self.objects.windows.get(window) orelse return error.UnknownWindow).node;
    }
};

fn resolveSelectionOutput(raw: ?*anyopaque, id: types.OutputId) ?wm.OutputId {
    const self: *const Adapter = @ptrCast(@alignCast(raw.?));
    return self.objects.outputs.get(id).?.wm_id;
}

fn resolveSelectionWindow(raw: ?*anyopaque, id: wm.WindowId) ?types.WindowId {
    const self: *const Adapter = @ptrCast(@alignCast(raw.?));
    return self.objects.wm_to_window.get(id);
}

fn validateSize(size: types.Size) !void {
    if (size.width <= 0 or size.height <= 0) return error.InvalidDimensions;
}

test "River layer-shell usable area replaces full output bounds" {
    const usable: wm.Rect = .{ .x = 0, .y = 32, .width = 1920, .height = 1048 };
    const spec = try reconcile.outputSpec(
        .{ .x = 0, .y = 0 },
        .{ .width = 1920, .height = 1080 },
        usable,
        null,
    );
    try std.testing.expectEqual(usable, spec.usable);
    try std.testing.expectEqual(@as(u32, 1080), spec.bounds.height);
}

fn currentCamera(world: *const wm.World, output: wm.OutputId) !f32 {
    const output_value = world.getOutput(output) orelse return error.UnknownOutput;
    const tag = world.getTag(output_value.active_tag) orelse return error.UnknownTag;
    return tag.camera.current;
}

fn protocolBits(value: anytype) u32 {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intCast(@intFromEnum(value)),
        .@"struct" => @bitCast(value),
        else => @compileError("River flags must be an enum or packed struct"),
    };
}

fn fakeRef(value: usize) types.ProxyRef {
    return types.ProxyRef.init(value) catch unreachable;
}

fn testPlanConfig() PlanConfig {
    return .{ .build_layout = testBuildLayout };
}

fn testBuildLayout(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    snapshot: *const wm.WorldView,
    output_id: wm.OutputId,
    sampled_camera: f32,
) !wm.LayoutPlans {
    const output = snapshot.getOutput(output_id) orelse return error.UnknownOutput;
    const tag = snapshot.getTag(output.active_tag) orelse return error.UnknownTag;
    const camera: wm.CameraTarget = .{
        .tag = tag.id,
        .current = sampled_camera,
        .target = sampled_camera,
        .strip_width = @floatFromInt(output.usable.width),
    };
    var result: wm.LayoutPlans = .{
        .manage = .{ .context = .{ .allocator = allocator, .epoch = snapshot.epoch(), .output = output_id, .camera = camera } },
        .render = .{ .context = .{ .allocator = allocator, .epoch = snapshot.epoch(), .output = output_id, .camera = camera } },
    };
    errdefer result.deinit();
    for (tag.columns.items) |column_id| {
        const column = snapshot.getColumn(column_id) orelse return error.UnknownColumn;
        if (column.root) |root| try appendTestNode(allocator, snapshot, root, column_id, output.usable, &result);
    }
    return result;
}

fn appendTestNode(
    allocator: std.mem.Allocator,
    snapshot: *const wm.WorldView,
    node_id: wm.NodeId,
    column: wm.ColumnId,
    rect: wm.Rect,
    result: *wm.LayoutPlans,
) !void {
    const node = snapshot.getNode(node_id) orelse return error.UnknownNode;
    if (node.window) |window_id| {
        const window = snapshot.getWindow(window_id) orelse return error.UnknownWindow;
        const virtual: wm.FRect = .{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .width = @floatFromInt(rect.width),
            .height = @floatFromInt(rect.height),
        };
        try result.manage.dimensions.append(allocator, .{
            .window = window_id,
            .column = column,
            .size = .{ .width = rect.width, .height = rect.height },
            .virtual = virtual,
        });
        try result.render.entries.append(allocator, .{
            .window = window_id,
            .column = column,
            .placement = window.placement,
            .target_virtual = virtual,
            .screen = rect,
            .clip = .{ .x = 0, .y = 0, .width = rect.width, .height = rect.height },
            .visible = true,
        });
        return;
    }
    for (node.children.items) |child| try appendTestNode(allocator, snapshot, child.id, column, rect, result);
}

test "generated River v5 forwarding edge type-checks" {
    _ = live_objects.Registry.bindLiveWindow;
    _ = live_objects.Registry.bindLiveOutput;
    _ = live_objects.Registry.bindLiveSeat;
    _ = events.onWindow;
    _ = events.onOutput;
    _ = events.onSeat;
    _ = events.onPointerBinding;
}

test "created River proxy kinds have typed binding and teardown seams" {
    var adapter = Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();

    const shell_ref = fakeRef(0xe000);
    const decoration_ref = fakeRef(0xe001);
    const binding_ref = fakeRef(0xe002);
    const shell = try adapter.objects.bindShellSurface(shell_ref);
    const decoration = try adapter.objects.bindDecoration(decoration_ref);
    const binding = try adapter.objects.bindPointerBinding(binding_ref);

    const counts = adapter.objects.counts();
    try std.testing.expectEqual(@as(usize, 1), counts.shell_surfaces);
    try std.testing.expectEqual(@as(usize, 1), counts.decorations);
    try std.testing.expectEqual(@as(usize, 1), counts.pointer_bindings);
    try std.testing.expectEqual(@as(usize, shell_ref.value), @intFromPtr(try adapter.objects.shellSurfaceProxy(shell)));
    try std.testing.expectEqual(@as(usize, decoration_ref.value), @intFromPtr(try adapter.objects.decorationProxy(decoration)));
    try std.testing.expectEqual(@as(usize, binding_ref.value), @intFromPtr(try adapter.objects.pointerBindingProxy(binding)));

    try std.testing.expectEqual(shell, try adapter.objects.unbindShellSurface(shell_ref));
    try std.testing.expectEqual(decoration, try adapter.objects.unbindLiveDecoration(@ptrFromInt(decoration_ref.value)));
    try std.testing.expectEqual(binding, try adapter.objects.unbindLivePointerBinding(@ptrFromInt(binding_ref.value)));
    try std.testing.expectEqual(@as(usize, 0), adapter.objects.counts().shell_surfaces);
    try std.testing.expectEqual(@as(usize, 0), adapter.objects.counts().decorations);
    try std.testing.expectEqual(@as(usize, 0), adapter.objects.counts().pointer_bindings);
}

test "fake River facts reconcile a WM world and compose one immutable frame epoch" {
    var adapter = Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();

    const output = try adapter.objects.bindOutput(fakeRef(0x1000));
    try adapter.stageManageFact(.{ .output_position = .{
        .output = output,
        .position = .{ .x = 40, .y = 20 },
    } });
    try adapter.stageManageFact(.{ .output_dimensions = .{
        .output = output,
        .size = .{ .width = 1280, .height = 720 },
    } });
    const window = try adapter.objects.bindWindow(fakeRef(0x2000), fakeRef(0x2001));

    var manage = try adapter.beginManage(testPlanConfig());
    defer manage.deinit();

    try std.testing.expectEqual(@as(usize, 2), manage.facts.facts().len);
    try std.testing.expectEqual(@as(usize, 1), manage.frames.frames().len);
    try std.testing.expectEqual(output, manage.frames.frames()[0].output);
    try std.testing.expectEqual(manage.epoch, manage.frames.frames()[0].plans.manage.context.epoch);
    try std.testing.expectEqual(manage.epoch, manage.frames.frames()[0].plans.render.context.epoch);
    try std.testing.expectEqual(@as(usize, 1), adapter.worldView().liveWindowCount());
    try std.testing.expectEqual(window, manage.frames.frames()[0].plans.river_manage.operations.items[0].propose_dimensions.window);
    try adapter.worldView().validate();
}

test "configured tags are reused by outputs in stable ordinal order" {
    var adapter = Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();
    try adapter.configureTags(&.{ "1", "2", "3" });

    const output = try adapter.objects.bindOutput(fakeRef(0x1100));
    try adapter.stageManageFact(.{ .output_position = .{ .output = output, .position = .{ .x = 0, .y = 0 } } });
    try adapter.stageManageFact(.{ .output_dimensions = .{ .output = output, .size = .{ .width = 800, .height = 600 } } });
    var manage = try adapter.beginManage(testPlanConfig());
    defer manage.deinit();

    const world = adapter.worldView();
    try std.testing.expectEqual(@as(usize, 3), world.liveTagCount());
    const first = world.tagAt(0).?;
    try std.testing.expectEqual(first, world.getOutput(try adapter.objects.wmOutputId(output)).?.active_tag);
    try std.testing.expectEqualStrings("1", world.getTag(first).?.name);
}

test "output reconciliation preserves workspace changes and places new windows there" {
    var adapter = Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();
    try adapter.configureTags(&.{ "1", "2", "3" });

    const output = try adapter.objects.bindOutput(fakeRef(0x1200));
    try adapter.stageManageFact(.{ .output_position = .{ .output = output, .position = .{ .x = 0, .y = 0 } } });
    try adapter.stageManageFact(.{ .output_dimensions = .{ .output = output, .size = .{ .width = 800, .height = 600 } } });
    var initial = try adapter.beginManage(testPlanConfig());
    initial.deinit();

    const output_id = try adapter.objects.wmOutputId(output);
    const second = adapter.world.tagAt(1).?;
    _ = try adapter.world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = output_id, .tag = second } } }});
    const window = try adapter.objects.bindWindow(fakeRef(0x2200), fakeRef(0x2201));

    var reconciled = try adapter.beginManage(testPlanConfig());
    defer reconciled.deinit();
    try std.testing.expectEqual(second, adapter.world.getOutput(output_id).?.active_tag);
    try std.testing.expectEqual(second, adapter.world.getWindow(try adapter.objects.wmWindowId(window)).?.tag);
}

test "all output plans in a manage cycle share one world epoch" {
    var adapter = Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();

    const first = try adapter.objects.bindOutput(fakeRef(0x3000));
    const second = try adapter.objects.bindOutput(fakeRef(0x4000));
    for ([_]types.OutputId{ first, second }, 0..) |output, index| {
        try adapter.stageManageFact(.{ .output_position = .{
            .output = output,
            .position = .{ .x = @intCast(index * 800), .y = 0 },
        } });
        try adapter.stageManageFact(.{ .output_dimensions = .{
            .output = output,
            .size = .{ .width = 800, .height = 600 },
        } });
    }

    var manage = try adapter.beginManage(testPlanConfig());
    defer manage.deinit();
    try std.testing.expectEqual(@as(usize, 2), manage.frames.frames().len);
    for (manage.frames.frames()) |frame| {
        try std.testing.expectEqual(manage.epoch, frame.plans.epoch);
        try std.testing.expectEqual(frame.plans.manage.context.epoch, frame.plans.render.context.epoch);
    }
}

test "consecutive render sequences reuse the latest manage frame set" {
    var adapter = Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();

    const output = try adapter.objects.bindOutput(fakeRef(0x5000));
    try adapter.stageManageFact(.{ .output_position = .{ .output = output, .position = .{ .x = 0, .y = 0 } } });
    try adapter.stageManageFact(.{ .output_dimensions = .{ .output = output, .size = .{ .width = 640, .height = 480 } } });
    const window = try adapter.objects.bindWindow(fakeRef(0x6000), fakeRef(0x6001));
    var first = try adapter.beginManage(testPlanConfig());
    defer first.deinit();

    try adapter.stageRenderFact(.{ .window_dimensions = .{
        .window = window,
        .size = .{ .width = 620, .height = 440 },
    } });
    var render = try adapter.beginRender(&first.frames);
    defer render.deinit();
    try std.testing.expectEqual(first.revision, render.revision);
    try std.testing.expectEqual(first.epoch, render.epoch);
    try std.testing.expectEqual(@as(usize, 1), render.facts.facts().len);
    var consecutive = try adapter.beginRender(&first.frames);
    defer consecutive.deinit();
    try std.testing.expectEqual(first.revision, consecutive.revision);
    try std.testing.expectEqual(@as(usize, 0), consecutive.facts.facts().len);
}

test "unknown related identities fail before entering a manage cycle" {
    var adapter = Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();

    const window = try adapter.objects.bindWindow(fakeRef(0x9000), fakeRef(0x9001));
    try std.testing.expectError(error.UnknownSeat, adapter.stageManageFact(.{ .seat_window_interaction = .{
        .window = window,
        .seat = types.SeatId.init(99),
    } }));
    try std.testing.expectEqual(@as(usize, 0), adapter.staged.manageCount());
    try std.testing.expect(!adapter.isPoisoned());
}

test "removing an output rematerializes its windows on the surviving output" {
    var adapter = Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();

    const first_ref = fakeRef(0xa000);
    const first = try adapter.objects.bindOutput(first_ref);
    const second = try adapter.objects.bindOutput(fakeRef(0xb000));
    for ([_]types.OutputId{ first, second }, 0..) |output, index| {
        try adapter.stageManageFact(.{ .output_position = .{
            .output = output,
            .position = .{ .x = @intCast(index * 1024), .y = 0 },
        } });
        try adapter.stageManageFact(.{ .output_dimensions = .{
            .output = output,
            .size = .{ .width = 1024, .height = 768 },
        } });
    }
    const window = try adapter.objects.bindWindow(fakeRef(0xc000), fakeRef(0xc001));
    var initial = try adapter.beginManage(testPlanConfig());
    defer initial.deinit();

    _ = try adapter.removeOutputRef(first_ref);
    var migrated = try adapter.beginManage(testPlanConfig());
    defer migrated.deinit();
    try std.testing.expectEqual(@as(usize, 1), migrated.frames.frames().len);
    try std.testing.expectEqual(second, migrated.frames.frames()[0].output);
    try std.testing.expectEqual(window, migrated.frames.frames()[0].plans.river_manage.operations.items[0].propose_dimensions.window);
    try std.testing.expectEqual(@as(usize, 1), adapter.worldView().liveWindowCount());
    try adapter.worldView().validate();
    try std.testing.expectError(error.StaleManageCycle, adapter.beginRender(&initial.frames));
}

fn checkWindowBindAllocationFailure(allocator: std.mem.Allocator) !void {
    var adapter = Adapter.init(allocator, .{});
    defer adapter.deinit();

    _ = adapter.objects.bindWindow(fakeRef(0xd000), fakeRef(0xd001)) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), adapter.objects.maps.windows.count());
        try std.testing.expectEqual(@as(usize, 0), adapter.objects.maps.nodes.count());
        try std.testing.expectEqual(@as(usize, 0), adapter.objects.windows.count());
        try std.testing.expectEqual(@as(usize, 0), adapter.objects.window_order.items.len);
        try std.testing.expectEqual(@as(usize, 0), adapter.staged.manageCount());
        return err;
    };
}

test "window identity binding is atomic under every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkWindowBindAllocationFailure,
        .{},
    );
}
