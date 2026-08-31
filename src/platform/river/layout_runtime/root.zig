//! Bounded Lua snapshot-to-layout-plan execution.
//!
//! The VM sees immutable protocol-free values and returns generic geometry.
//! It cannot call Wayland or mutate the authoritative WM world.

const std = @import("std");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");

pub const Limits = struct {
    max_instructions: u64 = 200_000,
    hook_granularity: u32 = 100,
    max_entries: usize = 4096,
    max_depth: usize = 256,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    vm: script.lua_vm.Vm,
    limits: Limits,
    instructions: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, limits: Limits) !Runtime {
        if (source.len == 0 or source.len > script.config.MaxLayoutSourceBytes)
            return error.InvalidLayoutSource;
        const vm = try script.lua_vm.Vm.init(true);
        var self: Runtime = .{
            .allocator = allocator,
            .vm = vm,
            .limits = limits,
        };
        errdefer self.vm.deinit();
        var chunk = std.ArrayList(u8).empty;
        defer chunk.deinit(allocator);
        try chunk.appendSlice(allocator, "local provider = (function()\n");
        try chunk.appendSlice(allocator, source);
        try chunk.appendSlice(
            allocator,
            "\nend)()\n" ++
                "if type(provider) == 'function' then provider = { layout = provider } end\n" ++
                "assert(type(provider) == 'table' and type(provider.layout) == 'function', " ++
                "'layout module must return a function or controller')\n" ++
                "whirlpool_layout_provider = provider",
        );
        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, &self, limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.run(chunk.items, "=whirlpool.layout.provider");
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.vm.clearInstructionHook();
        self.vm.deinit();
        self.* = undefined;
    }

    pub fn build(
        self: *Runtime,
        allocator: std.mem.Allocator,
        snapshot: *const wm.WorldView,
        output: wm.OutputId,
        sampled_camera: f32,
    ) !wm.LayoutPlans {
        return self.buildAt(allocator, snapshot, output, sampled_camera, 0);
    }

    pub fn buildAt(
        self: *Runtime,
        allocator: std.mem.Allocator,
        snapshot: *const wm.WorldView,
        output: wm.OutputId,
        sampled_camera: f32,
        monotonic_ms: f64,
    ) !wm.LayoutPlans {
        if (!std.math.isFinite(sampled_camera)) return error.InvalidCamera;
        if (!std.math.isFinite(monotonic_ms) or monotonic_ms < 0) return error.InvalidLayoutTime;
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, "layout");
        if (self.vm.luaType(-1) != .function) return error.InvalidLayoutSource;
        var count: usize = 0;
        try pushSnapshot(&self.vm, snapshot, output, monotonic_ms, &count, self.limits, 0);
        self.vm.pushNumber(sampled_camera);

        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, self, self.limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.call(2, 1);
        return parsePlans(allocator, &self.vm, snapshot, output, self.limits.max_entries);
    }

    /// Run one opaque configured action and append only validated, concrete
    /// identity operations returned by the retained Lua controller.
    pub fn handleAction(
        self: *Runtime,
        snapshot: *const wm.WorldView,
        output: wm.OutputId,
        name: []const u8,
        args: []const []const u8,
        intents: *script.IntentBatch,
    ) !void {
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, "action");
        if (self.vm.luaType(-1) != .function) return error.LayoutActionsUnsupported;
        var count: usize = 0;
        try pushSnapshot(&self.vm, snapshot, output, 0, &count, self.limits, 0);
        self.vm.createTable(0, 2);
        self.vm.pushString(name);
        self.vm.setField(-2, "name");
        self.vm.createTable(@intCast(args.len), 0);
        for (args, 0..) |arg, index| {
            self.vm.pushString(arg);
            self.vm.rawSetInteger(-2, @intCast(index + 1));
        }
        self.vm.setField(-2, "args");

        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, self, self.limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.call(2, 1);
        var parsed = script.IntentBatch.init(self.allocator, intents.limit - intents.count());
        defer parsed.deinit();
        try parseActionIntents(&self.vm, snapshot, &parsed);
        for (parsed.intents.items) |intent| try intents.append(intent);
    }

    /// Ask the retained provider for a bounded projection of the same model it
    /// uses to arrange windows. This is optional so geometry-only providers
    /// remain valid.
    pub fn project(
        self: *Runtime,
        allocator: std.mem.Allocator,
        snapshot: *const wm.WorldView,
        output: wm.OutputId,
    ) !?script.LayoutProjection {
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, "project");
        if (self.vm.luaType(-1) == .nil) return null;
        if (self.vm.luaType(-1) != .function) return error.InvalidLayoutSource;
        var count: usize = 0;
        try pushSnapshot(&self.vm, snapshot, output, 0, &count, self.limits, 0);

        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, self, self.limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.call(1, 1);
        return try parseProjection(allocator, &self.vm, snapshot, self.limits.max_entries);
    }

    pub fn buildHook(
        raw: ?*anyopaque,
        allocator: std.mem.Allocator,
        snapshot: *const wm.WorldView,
        output: wm.OutputId,
        sampled_camera: f32,
        monotonic_ms: f64,
    ) anyerror!wm.LayoutPlans {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingLayoutRuntime));
        return self.buildAt(allocator, snapshot, output, sampled_camera, monotonic_ms);
    }

    pub fn actionHook(
        raw: ?*anyopaque,
        snapshot: *const script.Snapshot,
        output: wm.OutputId,
        name: []const u8,
        args: []const []const u8,
        intents: *script.IntentBatch,
    ) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingLayoutRuntime));
        return self.handleAction(snapshot, output, name, args, intents);
    }

    pub fn projectHook(
        raw: ?*anyopaque,
        allocator: std.mem.Allocator,
        snapshot: *const wm.WorldView,
        output: wm.OutputId,
    ) anyerror!?script.LayoutProjection {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingLayoutRuntime));
        return self.project(allocator, snapshot, output);
    }

    fn instructionHook(raw: ?*anyopaque, amount: u64) callconv(.c) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        self.instructions = std.math.add(u64, self.instructions, amount) catch return false;
        return self.instructions <= self.limits.max_instructions;
    }
};

fn parseActionIntents(vm: *script.lua_vm.Vm, snapshot: *const wm.WorldView, intents: *script.IntentBatch) !void {
    if (vm.luaType(-1) == .nil) return;
    if (vm.luaType(-1) != .table) return error.InvalidLayoutActionResult;
    const count = vm.rawLength(-1);
    const base: c_int = @intCast(vm.stackDepth());
    for (0..count) |index| {
        vm.rawGetInteger(-1, @intCast(index + 1));
        if (vm.luaType(-1) != .table) return error.InvalidLayoutActionResult;
        const name = try stringField(vm, -1, "name");
        if (std.mem.eql(u8, name, "focus-window")) {
            const window = try idField(wm.WindowId, vm, -1, "window");
            _ = snapshot.getWindow(window) orelse return error.InvalidLayoutActionResult;
            try intents.append(.{ .focus_window = window });
        } else if (std.mem.eql(u8, name, "swap-nodes")) {
            const first = try idField(wm.NodeId, vm, -1, "first");
            const second = try idField(wm.NodeId, vm, -1, "second");
            _ = snapshot.getNode(first) orelse return error.InvalidLayoutActionResult;
            _ = snapshot.getNode(second) orelse return error.InvalidLayoutActionResult;
            try intents.append(.{ .swap_nodes = .{ .first = first, .second = second } });
        } else if (std.mem.eql(u8, name, "expel")) {
            const node = try idField(wm.NodeId, vm, -1, "node");
            _ = snapshot.getNode(node) orelse return error.InvalidLayoutActionResult;
            const direction_name = try stringField(vm, -1, "direction");
            const direction = std.meta.stringToEnum(wm.Direction, direction_name) orelse return error.InvalidLayoutActionResult;
            try intents.append(.{ .expel = .{ .node = node, .direction = direction } });
        } else if (std.mem.eql(u8, name, "close-window")) {
            const window = try idField(wm.WindowId, vm, -1, "window");
            _ = snapshot.getWindow(window) orelse return error.InvalidLayoutActionResult;
            try intents.append(.{ .close_window = window });
        } else if (std.mem.eql(u8, name, "summon-node")) {
            const node = try idField(wm.NodeId, vm, -1, "node");
            const output = try idField(wm.OutputId, vm, -1, "output");
            _ = snapshot.getNode(node) orelse return error.InvalidLayoutActionResult;
            _ = snapshot.getOutput(output) orelse return error.InvalidLayoutActionResult;
            try intents.append(.{ .summon_node = .{ .node = node, .output = output } });
        } else return error.InvalidLayoutActionResult;
        vm.setTop(base);
    }
}

fn parseProjection(
    allocator: std.mem.Allocator,
    vm: *script.lua_vm.Vm,
    snapshot: *const wm.WorldView,
    max_entries: usize,
) !script.LayoutProjection {
    if (vm.luaType(-1) != .table) return error.InvalidLayoutProjection;
    const count = vm.rawLength(-1);
    if (count > max_entries) return error.LayoutEntryLimitExceeded;
    var result = script.LayoutProjection.init(allocator);
    errdefer result.deinit();
    try result.tokens.ensureTotalCapacity(allocator, count);
    const base: c_int = @intCast(vm.stackDepth());
    for (0..count) |index| {
        vm.rawGetInteger(-1, @intCast(index + 1));
        if (vm.luaType(-1) != .table) return error.InvalidLayoutProjection;
        const kind_name = try stringField(vm, -1, "kind");
        const kind = std.meta.stringToEnum(script.layout_projection.Kind, kind_name) orelse
            return error.InvalidLayoutProjection;
        const window: ?wm.WindowId = if (kind == .window) try idField(wm.WindowId, vm, -1, "window") else null;
        if (window) |id| _ = snapshot.getWindow(id) orelse return error.InvalidLayoutProjection;
        result.tokens.appendAssumeCapacity(.{
            .kind = kind,
            .label = try script.layout_projection.Label.init(try optionalStringField(vm, -1, "label", "")),
            .window = window,
            .focused = try optionalBoolField(vm, -1, "focused", false),
            .selected = try optionalBoolField(vm, -1, "selected", false),
            .mark = try script.layout_projection.Label.init(try optionalStringField(vm, -1, "mark", "")),
        });
        vm.setTop(base);
    }
    return result;
}

fn pushSnapshot(
    vm: *script.lua_vm.Vm,
    snapshot: *const wm.WorldView,
    output_id: wm.OutputId,
    monotonic_ms: f64,
    count: *usize,
    limits: Limits,
    depth: usize,
) !void {
    const output = snapshot.getOutput(output_id) orelse return error.UnknownOutput;
    const tag = snapshot.getTag(output.active_tag) orelse return error.InvalidInvariant;
    vm.createTable(0, 4);
    try setId(vm, "epoch", snapshot.epoch());

    vm.createTable(0, 1);
    setNumber(vm, "monotonic_ms", monotonic_ms);
    vm.setField(-2, "clock");

    vm.createTable(0, 2);
    try setId(vm, "id", output_id.raw());
    vm.createTable(0, 4);
    setInteger(vm, "x", output.usable.x);
    setInteger(vm, "y", output.usable.y);
    setInteger(vm, "width", output.usable.width);
    setInteger(vm, "height", output.usable.height);
    vm.setField(-2, "usable");
    vm.setField(-2, "output");

    vm.createTable(0, 4);
    try setId(vm, "id", tag.id.raw());
    if (tag.focused) |focused| {
        try setId(vm, "focused", focused.raw());
    } else {
        vm.pushNil();
        vm.setField(-2, "focused");
    }
    vm.createTable(0, 2);
    setNumber(vm, "current", tag.camera.current);
    setNumber(vm, "target", tag.camera.target);
    vm.setField(-2, "camera");
    vm.createTable(tag.columns.items.len, 0);
    for (tag.columns.items, 0..) |column_id, index| {
        const column = snapshot.getColumn(column_id) orelse return error.InvalidInvariant;
        vm.createTable(0, 3);
        try setId(vm, "id", column.id.raw());
        setNumber(vm, "width", column.width);
        if (column.root) |root| {
            try pushNode(vm, snapshot, root, count, limits, depth + 1);
        } else vm.pushNil();
        vm.setField(-2, "root");
        vm.rawSetInteger(-2, @intCast(index + 1));
    }
    vm.setField(-2, "columns");
    vm.setField(-2, "tag");
}

fn pushNode(
    vm: *script.lua_vm.Vm,
    snapshot: *const wm.WorldView,
    node_id: wm.NodeId,
    count: *usize,
    limits: Limits,
    depth: usize,
) !void {
    if (depth > limits.max_depth) return error.LayoutTreeTooDeep;
    count.* += 1;
    if (count.* > limits.max_entries) return error.LayoutNodeLimitExceeded;
    const node = snapshot.getNode(node_id) orelse return error.InvalidInvariant;
    vm.createTable(0, 6);
    try setId(vm, "id", node.id.raw());
    try setId(vm, "column", node.column.raw());
    setString(vm, "axis", @tagName(node.axis));
    setInteger(vm, "active", node.active_child + 1);
    if (node.window) |window_id| {
        const window = snapshot.getWindow(window_id) orelse return error.InvalidInvariant;
        vm.createTable(0, 8);
        try setId(vm, "id", window.id.raw());
        setString(vm, "placement", @tagName(window.placement));
        setString(vm, "lifecycle", @tagName(window.lifecycle));
        try setId(vm, "focus_serial", window.focus_serial);
        pushOptionalSize(vm, window.actual_size);
        vm.setField(-2, "actual");
        pushOptionalSize(vm, window.proposed_size);
        vm.setField(-2, "proposed");
        vm.createTable(0, 4);
        setInteger(vm, "min_width", window.size_hints.min.width);
        setInteger(vm, "min_height", window.size_hints.min.height);
        setInteger(vm, "max_width", window.size_hints.max.width);
        setInteger(vm, "max_height", window.size_hints.max.height);
        vm.setField(-2, "size_hints");
        vm.createTable(0, 4);
        setInteger(vm, "x", window.floating_geometry.x);
        setInteger(vm, "y", window.floating_geometry.y);
        setInteger(vm, "width", window.floating_geometry.width);
        setInteger(vm, "height", window.floating_geometry.height);
        vm.setField(-2, "floating");
        vm.setField(-2, "window");
        vm.createTable(0, 0);
        vm.setField(-2, "children");
        return;
    }
    setString(vm, "mode", @tagName(node.mode orelse return error.InvalidInvariant));
    vm.createTable(node.children.items.len, 0);
    for (node.children.items, 0..) |child, index| {
        vm.createTable(0, 2);
        setNumber(vm, "weight", child.weight);
        try pushNode(vm, snapshot, child.id, count, limits, depth + 1);
        vm.setField(-2, "node");
        vm.rawSetInteger(-2, @intCast(index + 1));
    }
    vm.setField(-2, "children");
}

fn pushOptionalSize(vm: *script.lua_vm.Vm, value: ?wm.Size) void {
    const size = value orelse {
        vm.pushNil();
        return;
    };
    vm.createTable(0, 2);
    setInteger(vm, "width", size.width);
    setInteger(vm, "height", size.height);
}

fn setId(vm: *script.lua_vm.Vm, comptime name: [:0]const u8, value: u64) !void {
    vm.pushInteger(std.math.cast(i64, value) orelse return error.LayoutIdentityOverflow);
    vm.setField(-2, name);
}

fn setInteger(vm: *script.lua_vm.Vm, comptime name: [:0]const u8, value: anytype) void {
    vm.pushInteger(@intCast(value));
    vm.setField(-2, name);
}

fn setNumber(vm: *script.lua_vm.Vm, comptime name: [:0]const u8, value: anytype) void {
    vm.pushNumber(@floatCast(value));
    vm.setField(-2, name);
}

fn setString(vm: *script.lua_vm.Vm, comptime name: [:0]const u8, value: []const u8) void {
    vm.pushString(value);
    vm.setField(-2, name);
}

fn parsePlans(
    allocator: std.mem.Allocator,
    vm: *script.lua_vm.Vm,
    snapshot: *const wm.WorldView,
    output: wm.OutputId,
    max_entries: usize,
) !wm.LayoutPlans {
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    const epoch = try integerField(u64, vm, -1, "epoch");
    if (epoch != snapshot.epoch()) return error.PlanEpochMismatch;
    const tag = try idField(wm.TagId, vm, -1, "tag");
    const current = try numberField(vm, -1, "camera_current");
    const target = try numberField(vm, -1, "camera_target");
    const strip_width = try numberField(vm, -1, "strip_width");
    const needs_frame = try optionalBoolField(vm, -1, "needs_frame", false);
    if (!std.math.isFinite(current) or !std.math.isFinite(target) or !std.math.isFinite(strip_width) or strip_width < 0)
        return error.InvalidLayoutPlan;
    const camera: wm.CameraTarget = .{ .tag = tag, .current = current, .target = target, .strip_width = strip_width };
    var plans: wm.LayoutPlans = .{
        .manage = .{ .context = .{ .allocator = allocator, .epoch = epoch, .output = output, .camera = camera } },
        .render = .{ .context = .{ .allocator = allocator, .epoch = epoch, .output = output, .camera = camera } },
        .needs_frame = needs_frame,
    };
    errdefer plans.deinit();

    const base: c_int = @intCast(vm.stackDepth());
    vm.getField(-1, "entries");
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    const count = vm.rawLength(-1);
    if (count > max_entries) return error.LayoutEntryLimitExceeded;
    try plans.manage.dimensions.ensureTotalCapacity(allocator, count);
    try plans.render.entries.ensureTotalCapacity(allocator, count);
    for (0..count) |index| {
        vm.rawGetInteger(-1, @intCast(index + 1));
        if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
        const entry_index: c_int = @intCast(vm.stackDepth());
        const window = try idField(wm.WindowId, vm, -1, "window");
        const column = try idField(wm.ColumnId, vm, -1, "column");
        _ = snapshot.getWindow(window) orelse return error.InvalidLayoutPlan;
        _ = snapshot.getColumn(column) orelse return error.InvalidLayoutPlan;
        const placement_name = try stringField(vm, -1, "placement");
        const placement = std.meta.stringToEnum(wm.Placement, placement_name) orelse return error.InvalidLayoutPlan;
        const virtual = try floatRectField(vm, -1, "virtual");
        const screen = try rectField(vm, -1, "screen");
        const clip = try rectField(vm, -1, "clip");
        const window_clip = try optionalRectField(vm, -1, "window_clip");
        const visible = try boolField(vm, -1, "visible");
        const propose = try boolField(vm, -1, "propose");
        plans.render.entries.appendAssumeCapacity(.{
            .window = window,
            .column = column,
            .placement = placement,
            .target_virtual = virtual,
            .screen = screen,
            .clip = clip,
            .window_clip = window_clip,
            .visible = visible,
        });
        if (propose) plans.manage.dimensions.appendAssumeCapacity(.{
            .window = window,
            .column = column,
            .size = .{
                .width = @max(@as(u32, 1), @as(u32, @intFromFloat(@ceil(@max(virtual.width, 1))))),
                .height = @max(@as(u32, 1), @as(u32, @intFromFloat(@ceil(@max(virtual.height, 1))))),
            },
            .virtual = virtual,
        });
        vm.setTop(entry_index - 1);
    }
    vm.setTop(base);
    return plans;
}

fn fieldBase(vm: *script.lua_vm.Vm) c_int {
    return @intCast(vm.stackDepth());
}

fn integerField(comptime T: type, vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !T {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    const value = vm.integer(-1) orelse return error.InvalidLayoutPlan;
    return std.math.cast(T, value) orelse error.InvalidLayoutPlan;
}

fn idField(comptime T: type, vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !T {
    const raw = try integerField(u64, vm, index, name);
    const value: T = @bitCast(raw);
    if (!value.isValid()) return error.InvalidLayoutPlan;
    return value;
}

fn numberField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !f32 {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    const value = vm.number(-1) orelse return error.InvalidLayoutPlan;
    return @floatCast(value);
}

fn stringField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) ![]const u8 {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    return vm.string(-1) orelse error.InvalidLayoutPlan;
}

fn optionalStringField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8, default: []const u8) ![]const u8 {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    if (vm.luaType(-1) == .nil) return default;
    return vm.string(-1) orelse error.InvalidLayoutProjection;
}

fn boolField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !bool {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    return vm.boolean(-1) orelse error.InvalidLayoutPlan;
}

fn optionalBoolField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8, default: bool) !bool {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    if (vm.luaType(-1) == .nil) return default;
    return vm.boolean(-1) orelse error.InvalidLayoutPlan;
}

fn floatRectField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !wm.FRect {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    const value: wm.FRect = .{
        .x = try numberField(vm, -1, "x"),
        .y = try numberField(vm, -1, "y"),
        .width = try numberField(vm, -1, "width"),
        .height = try numberField(vm, -1, "height"),
    };
    if (!std.math.isFinite(value.x) or !std.math.isFinite(value.y) or
        !std.math.isFinite(value.width) or !std.math.isFinite(value.height) or
        value.width < 0 or value.height < 0) return error.InvalidLayoutPlan;
    return value;
}

fn rectField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !wm.Rect {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    return .{
        .x = try integerField(i32, vm, -1, "x"),
        .y = try integerField(i32, vm, -1, "y"),
        .width = try integerField(u32, vm, -1, "width"),
        .height = try integerField(u32, vm, -1, "height"),
    };
}

fn optionalRectField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !?wm.Rect {
    const base = fieldBase(vm);
    vm.getField(index, name);
    defer vm.setTop(base);
    if (vm.luaType(-1) == .nil) return null;
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    return .{
        .x = try integerField(i32, vm, -1, "x"),
        .y = try integerField(i32, vm, -1, "y"),
        .width = try integerField(u32, vm, -1, "width"),
        .height = try integerField(u32, vm, -1, "height"),
    };
}

test "bounded Lua provider turns an immutable snapshot into generic plans" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 10, .y = 20, .width = 300, .height = 200 },
        .usable = .{ .x = 10, .y = 20, .width = 300, .height = 200 },
    });
    const column = try world.createColumn(tag, .{});
    const window = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(window, column);
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(second, column);
    var snapshot = world.view();

    var runtime = try Runtime.init(std.testing.allocator,
        \\return function(snapshot, camera)
        \\  local column = snapshot.tag.columns[1]
        \\  local window = column.root.children[1].node.window
        \\  return {
        \\    epoch = snapshot.epoch, tag = snapshot.tag.id,
        \\    camera_current = camera, camera_target = snapshot.clock.monotonic_ms, strip_width = 320,
        \\    needs_frame = true,
        \\    entries = {{
        \\      window = window.id, column = column.id, placement = window.placement,
        \\      virtual = { x = 0, y = 0, width = 300, height = 200 },
        \\      screen = { x = 10, y = 20, width = 300, height = 200 },
        \\      clip = { x = 0, y = 0, width = 300, height = 200 },
        \\      visible = true, propose = true,
        \\    }},
        \\  }
        \\end
    , .{});
    defer runtime.deinit();
    var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 2, 5);
    defer plans.deinit();
    try std.testing.expectEqual(@as(usize, 1), plans.manage.dimensions.items.len);
    try std.testing.expectEqual(@as(usize, 1), plans.render.entries.items.len);
    try std.testing.expectEqual(window, plans.render.entries.items[0].window);
    try std.testing.expectEqual(@as(f32, 5), plans.render.context.camera.target);
    try std.testing.expect(plans.needs_frame);
}

fn loadScrollingSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "config/lib/scrolling.lua",
        allocator,
        .limited(script.config.MaxLayoutSourceBytes),
    );
}

test "sample scrolling provider moves camera to keep focus in the viewport" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
        .usable = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
    });
    var windows: [3]wm.WindowId = undefined;
    for (&windows) |*window| {
        const column = try world.createColumn(tag, .{ .width = 1 });
        window.* = try world.createWindow(.{ .tag = tag, .output = output });
        try world.manageWindow(window.*, column);
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[2] } }});
    var snapshot = world.view();
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    {
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 0);
        defer plans.deinit();
        try std.testing.expectEqual(@as(usize, 3), plans.render.entries.items.len);
        try std.testing.expect(plans.render.context.camera.target > 0);
        try std.testing.expectEqual(@as(f32, 0), plans.render.context.camera.current);
        try std.testing.expect(plans.needs_frame);
        try std.testing.expectEqual(@as(f32, 1032), plans.render.context.camera.strip_width);
    }
    {
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 90);
        defer plans.deinit();
        try std.testing.expect(plans.render.context.camera.current > 0);
        try std.testing.expect(plans.render.context.camera.current < plans.render.context.camera.target);
        try std.testing.expect(plans.needs_frame);
    }
    {
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 180);
        defer plans.deinit();
        try std.testing.expectEqual(plans.render.context.camera.target, plans.render.context.camera.current);
        try std.testing.expect(!plans.needs_frame);
        try std.testing.expectEqual(@as(u32, 0), plans.render.entries.items[0].clip.width);
        try std.testing.expectEqual(@as(u32, 328), plans.render.entries.items[2].clip.width);
    }
}

test "sample scrolling camera retargets from its interrupted position" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
        .usable = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
    });
    var windows: [3]wm.WindowId = undefined;
    for (&windows) |*window| {
        const column = try world.createColumn(tag, .{ .width = 1 });
        window.* = try world.createWindow(.{ .tag = tag, .output = output });
        try world.manageWindow(window.*, column);
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[2] } }});
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 0);
        plans.deinit();
    }
    var interrupted: f32 = undefined;
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 90);
        defer plans.deinit();
        interrupted = plans.render.context.camera.current;
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[0] } }});
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 90);
        defer plans.deinit();
        try std.testing.expectApproxEqAbs(interrupted, plans.render.context.camera.current, 0.01);
        try std.testing.expectEqual(@as(f32, 0), plans.render.context.camera.target);
        try std.testing.expect(plans.needs_frame);
    }
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 270);
        defer plans.deinit();
        try std.testing.expectEqual(@as(f32, 0), plans.render.context.camera.current);
        try std.testing.expect(!plans.needs_frame);
    }
}

test "sample scrolling provider preserves split geometry and tab visibility" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 1000, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 1000, .height = 600 },
    });
    const column = try world.createColumn(tag, .{ .width = 1 });
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, column);
    try world.manageWindow(second, column);
    const root = world.getColumn(column).?.root.?;
    const first_node = world.nodeForWindow(first).?;
    _ = try world.applyAtomically(&.{
        .{ .tree = .{ .set_container_mode = .{ .node = root, .mode = .split, .axis = .horizontal } } },
        .{ .geometry = .{ .resize_split = .{ .split = root, .child = first_node, .weight = 3 } } },
    });
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    {
        var snapshot = world.view();
        var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
        defer plans.deinit();
        try std.testing.expectEqual(@as(usize, 2), plans.render.entries.items.len);
        const first_width = plans.render.entries.items[0].target_virtual.width;
        const second_width = plans.render.entries.items[1].target_virtual.width;
        try std.testing.expectApproxEqAbs(@as(f32, 912), first_width + second_width, 0.01);
        try std.testing.expect(first_width > second_width * 2.9);
    }
    _ = try world.applyAtomically(&.{
        .{ .tree = .{ .set_container_mode = .{ .node = root, .mode = .tabbed, .axis = .horizontal } } },
        .{ .tree = .{ .set_active_tab = .{ .container = root, .child = world.nodeForWindow(second).? } } },
    });
    var snapshot = world.view();
    var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
    defer plans.deinit();
    var visible: usize = 0;
    for (plans.render.entries.items) |entry| visible += @intFromBool(entry.visible);
    try std.testing.expectEqual(@as(usize, 1), visible);
    try std.testing.expect(!plans.render.entries.items[0].visible);
    try std.testing.expect(plans.render.entries.items[1].visible);
}

test "camera pan preserves configured widths despite stale actual sizes" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
        .usable = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
    });
    var windows: [3]wm.WindowId = undefined;
    for (&windows, 0..) |*window, index| {
        const column = try world.createColumn(tag, .{ .width = 0.5 });
        window.* = try world.createWindow(.{
            .tag = tag,
            .output = output,
            .actual_size = .{ .width = if (index == 0) 500 else 156, .height = 200 },
            .proposed_size = .{ .width = 156, .height = 200 },
        });
        try world.manageWindow(window.*, column);
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[0] } }});
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();

    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 0);
        defer plans.deinit();
        try std.testing.expect(!plans.needs_frame);
        try expectConfiguredColumnsPacked(&plans);
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[2] } }});

    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 10);
        defer plans.deinit();
        try std.testing.expect(plans.needs_frame);
        try expectConfiguredColumnsPacked(&plans);
    }
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 100);
        defer plans.deinit();
        try std.testing.expect(plans.needs_frame);
        try std.testing.expect(plans.render.context.camera.current > 0);
        try expectConfiguredColumnsPacked(&plans);
    }
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 190);
        defer plans.deinit();
        try std.testing.expect(!plans.needs_frame);
        try std.testing.expectEqual(
            plans.render.context.camera.target,
            plans.render.context.camera.current,
        );
        try expectConfiguredColumnsPacked(&plans);
    }
}

test "Lua-owned strips move and focus across the cross axis with peeking" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
        .usable = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
    });
    var windows: [3]wm.WindowId = undefined;
    for (&windows) |*window| {
        const column = try world.createColumn(tag, .{ .width = 0.5 });
        window.* = try world.createWindow(.{ .tag = tag, .output = output });
        try world.manageWindow(window.*, column);
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[0] } }});
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 0);
        plans.deinit();
    }

    var intents = script.IntentBatch.init(std.testing.allocator, 4);
    defer intents.deinit();
    {
        var snapshot = world.view();
        try runtime.handleAction(&snapshot, output, "swap-down", &.{}, &intents);
    }
    try std.testing.expectEqual(@as(usize, 0), intents.count());

    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 10);
        defer plans.deinit();
        const moved = renderEntryForWindow(&plans, windows[0]).?;
        const above = renderEntryForWindow(&plans, windows[1]).?;
        try std.testing.expect(moved.target_virtual.y > above.target_virtual.y);
        try std.testing.expect(plans.needs_frame);
    }
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 190);
        defer plans.deinit();
        const above = renderEntryForWindow(&plans, windows[1]).?;
        const moved = renderEntryForWindow(&plans, windows[0]).?;
        try std.testing.expect(above.clip.height > 0);
        try std.testing.expect(moved.clip.height > 0);
        try std.testing.expect(!plans.needs_frame);
    }

    {
        var snapshot = world.view();
        try runtime.handleAction(&snapshot, output, "focus-up", &.{}, &intents);
    }
    try std.testing.expectEqual(@as(usize, 1), intents.count());
    var commands: [4]wm.Command = undefined;
    const command_count = try intents.translate(&commands);
    _ = try world.applyAtomically(commands[0..command_count]);
    try std.testing.expectEqual(windows[1], world.getNode(world.getTag(tag).?.focused.?).?.window.?);
}

test "layout projection exposes strips, insertion target, and floating windows from one model" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 500, .height = 300 },
        .usable = .{ .x = 0, .y = 0, .width = 500, .height = 300 },
    });
    const first_column = try world.createColumn(tag, .{});
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, first_column);
    const second_column = try world.createColumn(tag, .{});
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(second, second_column);
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = first } }});

    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    {
        var snapshot = world.view();
        var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
        plans.deinit();
        var intents = script.IntentBatch.init(std.testing.allocator, 2);
        defer intents.deinit();
        try runtime.handleAction(&snapshot, output, "swap-down", &.{}, &intents);
        try std.testing.expectEqual(@as(usize, 0), intents.count());
    }
    {
        var snapshot = world.view();
        var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
        plans.deinit();
    }
    const third_column = try world.createColumn(tag, .{});
    const third = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(third, third_column);
    const floating_column = try world.createColumn(tag, .{});
    const floating = try world.createWindow(.{ .tag = tag, .output = output, .placement = .floating });
    try world.manageWindow(floating, floating_column);

    var snapshot = world.view();
    var projection = (try runtime.project(std.testing.allocator, &snapshot, output)).?;
    defer projection.deinit();
    var group_count: usize = 0;
    var insertion_count: usize = 0;
    var saw_float = false;
    var depth: usize = 0;
    var first_depth: ?usize = null;
    var third_depth: ?usize = null;
    for (projection.tokens.items) |token| switch (token.kind) {
        .group_open => {
            depth += 1;
            group_count += 1;
            saw_float = saw_float or std.mem.eql(u8, token.label.slice(), "float");
        },
        .group_close => depth -= 1,
        .insertion => insertion_count += 1,
        .window => {
            if (token.window.? == first) first_depth = depth;
            if (token.window.? == third) third_depth = depth;
        },
    };
    try std.testing.expect(group_count >= 3);
    try std.testing.expectEqual(@as(usize, 1), insertion_count);
    try std.testing.expect(saw_float);
    try std.testing.expectEqual(first_depth, third_depth);
    try std.testing.expect(floating != first and second != third);
}

test "structural marks close and summon complete selected groups" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const source_tag = try world.createTag();
    const destination_tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = source_tag,
        .bounds = .{ .x = 0, .y = 0, .width = 500, .height = 300 },
        .usable = .{ .x = 0, .y = 0, .width = 500, .height = 300 },
    });
    const column = try world.createColumn(source_tag, .{});
    const first = try world.createWindow(.{ .tag = source_tag, .output = output });
    const second = try world.createWindow(.{ .tag = source_tag, .output = output });
    try world.manageWindow(first, column);
    try world.manageWindow(second, column);
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = first } }});

    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    var intents = script.IntentBatch.init(std.testing.allocator, 8);
    defer intents.deinit();
    {
        var snapshot = world.view();
        var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
        plans.deinit();
        try runtime.handleAction(&snapshot, output, "select-parent", &.{}, &intents);
        try runtime.handleAction(&snapshot, output, "mark", &.{"pair"}, &intents);
        try runtime.handleAction(&snapshot, output, "close-selection", &.{}, &intents);
    }
    try std.testing.expectEqual(@as(usize, 2), intents.count());
    intents.clear();
    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = output, .tag = destination_tag } } }});
    {
        var snapshot = world.view();
        var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
        plans.deinit();
        try runtime.handleAction(&snapshot, output, "summon", &.{"pair"}, &intents);
    }
    try std.testing.expectEqual(@as(usize, 1), intents.count());
    var commands: [8]wm.Command = undefined;
    const count = try intents.translate(&commands);
    _ = try world.applyAtomically(commands[0..count]);
    try std.testing.expectEqual(destination_tag, world.getWindow(first).?.tag);
    try std.testing.expectEqual(destination_tag, world.getWindow(second).?.tag);
    try std.testing.expectEqual(
        world.getNode(world.nodeForWindow(first).?).?.column,
        world.getNode(world.nodeForWindow(second).?).?.column,
    );
}

test "cross-axis movement extracts only the focused window from a shared column" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
        .usable = .{ .x = 0, .y = 0, .width = 400, .height = 240 },
    });
    const column = try world.createColumn(tag, .{ .width = 0.5 });
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, column);
    try world.manageWindow(second, column);
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = first } }});
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 0);
        plans.deinit();
    }

    var intents = script.IntentBatch.init(std.testing.allocator, 2);
    defer intents.deinit();
    {
        var snapshot = world.view();
        try runtime.handleAction(&snapshot, output, "swap-up", &.{}, &intents);
    }
    try std.testing.expectEqual(@as(usize, 1), intents.count());
    var commands: [2]wm.Command = undefined;
    const command_count = try intents.translate(&commands);
    _ = try world.applyAtomically(commands[0..command_count]);
    try std.testing.expect(world.getNode(world.nodeForWindow(first).?).?.column !=
        world.getNode(world.nodeForWindow(second).?).?.column);

    var snapshot = world.view();
    var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 10);
    defer plans.deinit();
    try std.testing.expect(
        renderEntryForWindow(&plans, first).?.target_virtual.y <
            renderEntryForWindow(&plans, second).?.target_virtual.y,
    );
}

test "Lua main and cross axes support vertical and reversed presentations" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 240, .height = 400 },
        .usable = .{ .x = 0, .y = 0, .width = 240, .height = 400 },
    });
    var windows: [2]wm.WindowId = undefined;
    for (&windows) |*window| {
        const column = try world.createColumn(tag, .{ .width = 0.5 });
        window.* = try world.createWindow(.{ .tag = tag, .output = output });
        try world.manageWindow(window.*, column);
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[0] } }});
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    const vertical_source = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        source,
        "local main_axis = \"horizontal\"",
        "local main_axis = \"vertical\"",
    );
    defer std.testing.allocator.free(vertical_source);
    var intents = script.IntentBatch.init(std.testing.allocator, 4);
    defer intents.deinit();
    {
        var runtime = try Runtime.init(std.testing.allocator, vertical_source, .{});
        defer runtime.deinit();
        {
            var snapshot = world.view();
            var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 0);
            plans.deinit();
        }
        {
            var snapshot = world.view();
            try runtime.handleAction(&snapshot, output, "swap-right", &.{}, &intents);
        }
        try std.testing.expectEqual(@as(usize, 0), intents.count());
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 10);
        defer plans.deinit();
        try std.testing.expect(
            renderEntryForWindow(&plans, windows[0]).?.target_virtual.x >
                renderEntryForWindow(&plans, windows[1]).?.target_virtual.x,
        );
    }

    const reversed_source = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        source,
        "local main_reverse = false",
        "local main_reverse = true",
    );
    defer std.testing.allocator.free(reversed_source);
    {
        var runtime = try Runtime.init(std.testing.allocator, reversed_source, .{});
        defer runtime.deinit();
        {
            var snapshot = world.view();
            var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 0);
            plans.deinit();
        }
        {
            var snapshot = world.view();
            try runtime.handleAction(&snapshot, output, "focus-left", &.{}, &intents);
        }
        try std.testing.expectEqual(@as(usize, 1), intents.count());
        try std.testing.expectEqual(windows[1], intents.intents.items[0].focus_window);
    }
}

fn renderEntryForWindow(plans: *const wm.LayoutPlans, window: wm.WindowId) ?wm.RenderEntry {
    for (plans.render.entries.items) |entry| if (entry.window == window) return entry;
    return null;
}

test "tiled vertical motion animates without changing camera-driven x" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 1000, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 1000, .height = 600 },
    });
    const column = try world.createColumn(tag, .{ .width = 1 });
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, column);
    try world.manageWindow(second, column);
    const root = world.getColumn(column).?.root.?;
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();

    var initial_y: i32 = undefined;
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 0);
        defer plans.deinit();
        initial_y = plans.render.entries.items[1].screen.y;
        try std.testing.expect(!plans.needs_frame);
    }
    _ = try world.applyAtomically(&.{.{ .tree = .{ .set_container_mode = .{
        .node = root,
        .mode = .split,
        .axis = .horizontal,
    } } }});

    var target: wm.FRect = undefined;
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 10);
        defer plans.deinit();
        const entry = plans.render.entries.items[1];
        target = entry.target_virtual;
        try std.testing.expectEqual(
            @as(i32, @intFromFloat(@floor(target.x - plans.render.context.camera.current))),
            entry.screen.x,
        );
        try std.testing.expectEqual(initial_y, entry.screen.y);
        try std.testing.expect(plans.needs_frame);
    }
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 100);
        defer plans.deinit();
        const entry = plans.render.entries.items[1];
        try std.testing.expectEqual(
            @as(i32, @intFromFloat(@floor(target.x - plans.render.context.camera.current))),
            entry.screen.x,
        );
        try std.testing.expect(entry.screen.y > @as(i32, @intFromFloat(@floor(target.y))));
        try std.testing.expect(entry.screen.y < initial_y);
        try std.testing.expect(plans.needs_frame);
    }
    {
        var snapshot = world.view();
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0, 190);
        defer plans.deinit();
        try std.testing.expectEqual(
            @as(i32, @intFromFloat(@floor(target.y))),
            plans.render.entries.items[1].screen.y,
        );
        try std.testing.expect(!plans.needs_frame);
    }
}

fn expectConfiguredColumnsPacked(plans: *const wm.LayoutPlans) !void {
    const camera = plans.render.context.camera.current;
    const entries = plans.render.entries.items;
    for (entries) |entry| {
        try std.testing.expectEqual(
            @as(i32, @intFromFloat(@floor(entry.target_virtual.x - camera))),
            entry.screen.x,
        );
        try std.testing.expectEqual(entries[0].target_virtual.width, entry.target_virtual.width);
    }
    for (entries[0 .. entries.len - 1], entries[1..]) |left, right| {
        const virtual_gap = right.target_virtual.x - (left.target_virtual.x + left.target_virtual.width);
        try std.testing.expectEqual(@as(f32, 16), virtual_gap);
    }
}

test "sample scrolling provider keeps configured gaps between adjacent columns" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 1000, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 1000, .height = 600 },
    });
    var windows: [2]wm.WindowId = undefined;
    for (&windows) |*window| {
        const column = try world.createColumn(tag, .{ .width = 0.5 });
        window.* = try world.createWindow(.{ .tag = tag, .output = output });
        try world.manageWindow(window.*, column);
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[1] } }});

    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    var snapshot = world.view();
    var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
    defer plans.deinit();

    const left = plans.render.entries.items[0].screen;
    const right = plans.render.entries.items[1].screen;
    const border_width: i32 = 4;
    const gap = (right.x - border_width) -
        (left.x + @as(i32, @intCast(left.width)) + border_width);
    try std.testing.expectEqual(@as(i32, 8), gap);
    try std.testing.expectEqual(@as(f32, 0), plans.render.context.camera.current);
    try std.testing.expectEqual(@as(f32, 0), plans.render.context.camera.target);
}

test "confirmed width floor expands every window in a vertical column" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 500, .height = 400 },
        .usable = .{ .x = 0, .y = 0, .width = 500, .height = 400 },
    });
    const column = try world.createColumn(tag, .{ .width = 0.5 });
    const reluctant = try world.createWindow(.{
        .tag = tag,
        .output = output,
        .size_hints = .{ .min = .{ .width = 360, .height = 0 } },
        .actual_size = .{ .width = 360, .height = 100 },
        .proposed_size = .{ .width = 200, .height = 100 },
    });
    const sibling = try world.createWindow(.{
        .tag = tag,
        .output = output,
        .actual_size = .{ .width = 200, .height = 100 },
        .proposed_size = .{ .width = 200, .height = 100 },
    });
    try world.manageWindow(reluctant, column);
    try world.manageWindow(sibling, column);
    try std.testing.expectEqual(wm.Axis.vertical, world.getNode(world.getColumn(column).?.root.?).?.axis);

    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    var snapshot = world.view();
    var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
    defer plans.deinit();

    try std.testing.expectEqual(@as(usize, 2), plans.manage.dimensions.items.len);
    try std.testing.expectEqual(@as(u32, 360), plans.manage.dimensions.items[0].size.width);
    try std.testing.expectEqual(@as(u32, 360), plans.manage.dimensions.items[1].size.width);
    try std.testing.expectEqual(
        plans.render.entries.items[0].screen.x,
        plans.render.entries.items[1].screen.x,
    );
}

test "sample scrolling provider renders floating geometry" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 10, .y = 20, .width = 500, .height = 300 },
        .usable = .{ .x = 10, .y = 20, .width = 500, .height = 300 },
    });
    const column = try world.createColumn(tag, .{});
    const window = try world.createWindow(.{
        .tag = tag,
        .output = output,
        .placement = .floating,
        .floating_geometry = .{ .x = 70, .y = 80, .width = 220, .height = 140 },
    });
    try world.manageWindow(window, column);

    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    var snapshot = world.view();
    var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
    defer plans.deinit();

    try std.testing.expectEqual(@as(usize, 1), plans.manage.dimensions.items.len);
    try std.testing.expectEqual(wm.Size{ .width = 220, .height = 140 }, plans.manage.dimensions.items[0].size);
    try std.testing.expect(plans.render.entries.items[0].visible);
    try std.testing.expectEqual(wm.Rect{ .x = 70, .y = 80, .width = 220, .height = 140 }, plans.render.entries.items[0].screen);
}

test "sample scrolling provider isolates fullscreen from floating and scratchpad" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 10, .y = 20, .width = 500, .height = 300 },
        .usable = .{ .x = 10, .y = 20, .width = 500, .height = 300 },
    });
    var windows: [3]wm.WindowId = undefined;
    for (&windows) |*window| {
        const column = try world.createColumn(tag, .{});
        window.* = try world.createWindow(.{ .tag = tag, .output = output });
        try world.manageWindow(window.*, column);
    }
    _ = try world.applyAtomically(&.{
        .{ .window = .{ .set_placement = .{ .window = windows[0], .placement = .floating } } },
        .{ .window = .{ .set_placement = .{ .window = windows[1], .placement = .scratchpad } } },
        .{ .window = .{ .set_placement = .{ .window = windows[2], .placement = .fullscreen } } },
        .{ .focus = .{ .window = windows[2] } },
    });
    var snapshot = world.view();
    const source = try loadScrollingSource(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    var plans = try runtime.build(std.testing.allocator, &snapshot, output, 0);
    defer plans.deinit();

    try std.testing.expectEqual(@as(usize, 3), plans.render.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), plans.manage.dimensions.items.len);
    for (plans.render.entries.items) |entry| {
        if (entry.window == windows[2]) {
            try std.testing.expect(entry.visible);
            try std.testing.expectEqual(@as(f32, 500), entry.target_virtual.width);
            try std.testing.expectEqual(@as(f32, 300), entry.target_virtual.height);
            try std.testing.expectEqual(@as(i32, 10), entry.screen.x);
            try std.testing.expectEqual(@as(i32, 20), entry.screen.y);
        } else {
            try std.testing.expect(!entry.visible);
            try std.testing.expectEqual(@as(u32, 0), entry.clip.width);
        }
    }
}
