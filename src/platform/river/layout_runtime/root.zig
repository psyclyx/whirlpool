//! Bounded Lua execution over flat compositor facts and per-window effects.

const std = @import("std");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");

pub const Limits = struct {
    max_instructions: u64 = 200_000,
    hook_granularity: u32 = 100,
    max_entries: usize = 4096,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    vm: script.lua_vm.Vm,
    limits: Limits,
    instructions: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, limits: Limits) !Runtime {
        if (source.len == 0 or source.len > script.config.MaxLayoutSourceBytes) return error.InvalidLayoutSource;
        const vm = try script.lua_vm.Vm.init(true);
        var self: Runtime = .{ .allocator = allocator, .vm = vm, .limits = limits };
        errdefer self.vm.deinit();
        var chunk = std.ArrayList(u8).empty;
        defer chunk.deinit(allocator);
        try chunk.appendSlice(allocator, "local provider = (function()\n");
        try chunk.appendSlice(allocator, source);
        try chunk.appendSlice(allocator, "\nend)()\n" ++
            "if type(provider) == 'function' then provider = { layout = provider } end\n" ++
            "assert(type(provider) == 'table' and type(provider.layout) == 'function', " ++
            "'layout module must return a function or controller')\n" ++
            "whirlpool_layout_provider = provider");
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

    pub fn buildAt(self: *Runtime, allocator: std.mem.Allocator, snapshot: *const wm.WorldView, output: wm.OutputId, monotonic_ms: f64) !wm.LayoutPlans {
        if (!std.math.isFinite(monotonic_ms) or monotonic_ms < 0) return error.InvalidLayoutTime;
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, "layout");
        if (self.vm.luaType(-1) != .function) return error.InvalidLayoutSource;
        try pushSnapshot(&self.vm, snapshot, output, monotonic_ms, self.limits.max_entries);
        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, self, self.limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.call(1, 1);
        return parsePlans(allocator, &self.vm, snapshot, output, self.limits.max_entries);
    }

    pub fn handleAction(self: *Runtime, snapshot: *const wm.WorldView, output: wm.OutputId, name: []const u8, args: []const []const u8, intents: *script.IntentBatch) !void {
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, "action");
        if (self.vm.luaType(-1) != .function) return error.LayoutActionsUnsupported;
        try pushSnapshot(&self.vm, snapshot, output, 0, self.limits.max_entries);
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

    pub fn beginActions(self: *Runtime) !void {
        return self.callActionBoundary("begin_actions", null);
    }

    pub fn finishActions(self: *Runtime, commit: bool) !void {
        return self.callActionBoundary("finish_actions", commit);
    }

    pub fn project(self: *Runtime, allocator: std.mem.Allocator, snapshot: *const wm.WorldView, output: wm.OutputId) !?script.LayoutProjection {
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, "project");
        if (self.vm.luaType(-1) == .nil) return null;
        if (self.vm.luaType(-1) != .function) return error.InvalidLayoutSource;
        try pushSnapshot(&self.vm, snapshot, output, 0, self.limits.max_entries);
        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, self, self.limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.call(1, 1);
        return try parseProjection(allocator, &self.vm, snapshot, self.limits.max_entries);
    }

    pub fn buildHook(raw: ?*anyopaque, allocator: std.mem.Allocator, snapshot: *const wm.WorldView, output: wm.OutputId, monotonic_ms: f64) anyerror!wm.LayoutPlans {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingLayoutRuntime));
        return self.buildAt(allocator, snapshot, output, monotonic_ms);
    }

    pub fn actionHook(raw: ?*anyopaque, snapshot: *const script.Snapshot, output: wm.OutputId, name: []const u8, args: []const []const u8, intents: *script.IntentBatch) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingLayoutRuntime));
        return self.handleAction(snapshot, output, name, args, intents);
    }

    pub fn beginActionsHook(raw: ?*anyopaque) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingLayoutRuntime));
        return self.beginActions();
    }

    pub fn finishActionsHook(raw: ?*anyopaque, commit: bool) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingLayoutRuntime));
        return self.finishActions(commit);
    }

    pub fn projectHook(raw: ?*anyopaque, allocator: std.mem.Allocator, snapshot: *const wm.WorldView, output: wm.OutputId) anyerror!?script.LayoutProjection {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse return error.MissingLayoutRuntime));
        return self.project(allocator, snapshot, output);
    }

    fn instructionHook(raw: ?*anyopaque, amount: u64) callconv(.c) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        self.instructions = std.math.add(u64, self.instructions, amount) catch return false;
        return self.instructions <= self.limits.max_instructions;
    }

    fn callActionBoundary(self: *Runtime, comptime name: [:0]const u8, commit: ?bool) !void {
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, name);
        if (self.vm.luaType(-1) == .nil) return;
        if (self.vm.luaType(-1) != .function) return error.InvalidLayoutSource;
        const argument_count: u31 = if (commit) |value| blk: {
            self.vm.pushBoolean(value);
            break :blk 1;
        } else 0;
        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, self, self.limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.call(argument_count, 0);
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
            const window = try liveId(wm.WindowId, vm, snapshot, -1, "window");
            try intents.append(.{ .focus_window = window });
        } else if (std.mem.eql(u8, name, "clear-focus")) {
            try intents.append(.clear_focus);
        } else if (std.mem.eql(u8, name, "close-window")) {
            const window = try liveId(wm.WindowId, vm, snapshot, -1, "window");
            try intents.append(.{ .close_window = window });
        } else if (std.mem.eql(u8, name, "move-window")) {
            const window = try liveId(wm.WindowId, vm, snapshot, -1, "window");
            const tag = try liveId(wm.TagId, vm, snapshot, -1, "tag");
            const output = try optionalIdField(wm.OutputId, vm, -1, "output");
            if (output) |id| _ = snapshot.getOutput(id) orelse return error.InvalidLayoutActionResult;
            try intents.append(.{ .assign_window = .{ .window = window, .tag = tag, .output = output } });
        } else if (std.mem.eql(u8, name, "set-active-tag")) {
            const output = try liveId(wm.OutputId, vm, snapshot, -1, "output");
            const tag = try liveId(wm.TagId, vm, snapshot, -1, "tag");
            try intents.append(.{ .set_active_tag = .{ .output = output, .tag = tag } });
        } else if (std.mem.eql(u8, name, "set-window-state")) {
            const window = try liveId(wm.WindowId, vm, snapshot, -1, "window");
            const placement = std.meta.stringToEnum(wm.Placement, try stringField(vm, -1, "state")) orelse return error.InvalidLayoutActionResult;
            try intents.append(.{ .set_placement = .{ .window = window, .placement = placement } });
        } else if (std.mem.eql(u8, name, "set-floating-geometry")) {
            const window = try liveId(wm.WindowId, vm, snapshot, -1, "window");
            try intents.append(.{ .set_floating_geometry = .{ .window = window, .geometry = try rectField(vm, -1, "geometry") } });
        } else return error.InvalidLayoutActionResult;
        vm.setTop(base);
    }
}

fn parseProjection(allocator: std.mem.Allocator, vm: *script.lua_vm.Vm, snapshot: *const wm.WorldView, max_entries: usize) !script.LayoutProjection {
    if (vm.luaType(-1) != .table) return error.InvalidLayoutProjection;
    const count = vm.rawLength(-1);
    if (count > max_entries) return error.LayoutEntryLimitExceeded;
    var result = script.LayoutProjection.init(allocator);
    errdefer result.deinit();
    try result.items.ensureTotalCapacity(allocator, count);
    const base: c_int = @intCast(vm.stackDepth());
    for (0..count) |index| {
        vm.rawGetInteger(-1, @intCast(index + 1));
        const window = try optionalIdField(wm.WindowId, vm, -1, "window");
        if (window) |id| if (snapshot.getWindow(id) == null) return error.InvalidLayoutProjection;
        const width = try optionalIntegerField(u32, vm, -1, "width", 1);
        if (width == 0) return error.InvalidLayoutProjection;
        const action_args = try actionArgsField(vm, -1);
        result.items.appendAssumeCapacity(.{
            .style = try script.layout_projection.Label.init(try optionalStringField(vm, -1, "style", "")),
            .text = try script.layout_projection.Label.init(try optionalStringField(vm, -1, "text", "")),
            .detail = try script.layout_projection.Label.init(try optionalStringField(vm, -1, "detail", "")),
            .window = window,
            .focused = try optionalBoolField(vm, -1, "focused", false),
            .width = width,
            .action = try script.layout_projection.Label.init(try optionalStringField(vm, -1, "action", "")),
            .args = action_args.values,
            .arg_count = action_args.len,
        });
        vm.setTop(base);
    }
    return result;
}

fn pushSnapshot(vm: *script.lua_vm.Vm, snapshot: *const wm.WorldView, selected_output: wm.OutputId, monotonic_ms: f64, max_entries: usize) !void {
    const output = snapshot.getOutput(selected_output) orelse return error.UnknownOutput;
    if (snapshot.liveWindowCount() + snapshot.liveOutputCount() + snapshot.liveTagCount() > max_entries) return error.LayoutEntryLimitExceeded;
    vm.createTable(0, 8);
    try setId(vm, "epoch", snapshot.epoch());
    vm.createTable(0, 1);
    setNumber(vm, "monotonic_ms", monotonic_ms);
    vm.setField(-2, "clock");
    vm.createTable(0, 3);
    try setId(vm, "id", selected_output.raw());
    try setId(vm, "active_tag", output.active_tag.raw());
    pushRect(vm, output.usable);
    vm.setField(-2, "usable");
    vm.setField(-2, "output");
    vm.createTable(0, 2);
    try setId(vm, "id", output.active_tag.raw());
    if (snapshot.focusedWindow()) |focused| try setId(vm, "focused_window", focused.raw()) else setNil(vm, "focused_window");
    vm.setField(-2, "tag");

    vm.createTable(@intCast(snapshot.liveOutputCount()), 0);
    var ordinal: usize = 0;
    while (snapshot.outputAt(ordinal)) |id| : (ordinal += 1) {
        const item = snapshot.getOutput(id) orelse return error.InvalidInvariant;
        vm.createTable(0, 5);
        try setId(vm, "id", id.raw());
        try setId(vm, "active_tag", item.active_tag.raw());
        pushRect(vm, item.bounds);
        vm.setField(-2, "bounds");
        pushRect(vm, item.usable);
        vm.setField(-2, "usable");
        vm.rawSetInteger(-2, @intCast(ordinal + 1));
    }
    vm.setField(-2, "outputs");

    vm.createTable(@intCast(snapshot.liveTagCount()), 0);
    ordinal = 0;
    while (snapshot.tagAt(ordinal)) |id| : (ordinal += 1) {
        const item = snapshot.getTag(id) orelse return error.InvalidInvariant;
        vm.createTable(0, 2);
        try setId(vm, "id", id.raw());
        setString(vm, "name", item.name);
        vm.rawSetInteger(-2, @intCast(ordinal + 1));
    }
    vm.setField(-2, "tags");

    vm.createTable(@intCast(snapshot.liveWindowCount()), 0);
    ordinal = 0;
    while (snapshot.windowAt(ordinal)) |id| : (ordinal += 1) {
        const item = snapshot.getWindow(id) orelse return error.InvalidInvariant;
        vm.createTable(0, 12);
        try setId(vm, "id", id.raw());
        try setId(vm, "tag", item.tag.raw());
        if (item.output) |value| try setId(vm, "output", value.raw()) else setNil(vm, "output");
        setString(vm, "state", @tagName(item.placement));
        setString(vm, "lifecycle", @tagName(item.lifecycle));
        setBool(vm, "transient", item.transient);
        setInteger(vm, "focus_serial", @as(u8, if (snapshot.focusedWindow() == id) 1 else 0));
        pushOptionalSize(vm, item.actual_size);
        vm.setField(-2, "actual");
        pushOptionalSize(vm, item.proposed_size);
        vm.setField(-2, "proposed");
        vm.createTable(0, 2);
        vm.createTable(0, 2);
        setInteger(vm, "width", item.size_hints.min.width);
        setInteger(vm, "height", item.size_hints.min.height);
        vm.setField(-2, "min");
        vm.createTable(0, 2);
        setInteger(vm, "width", item.size_hints.max.width);
        setInteger(vm, "height", item.size_hints.max.height);
        vm.setField(-2, "max");
        vm.setField(-2, "size_hints");
        pushRect(vm, item.floating_geometry);
        vm.setField(-2, "floating");
        vm.rawSetInteger(-2, @intCast(ordinal + 1));
    }
    vm.setField(-2, "windows");
}

fn parsePlans(allocator: std.mem.Allocator, vm: *script.lua_vm.Vm, snapshot: *const wm.WorldView, output: wm.OutputId, max_entries: usize) !wm.LayoutPlans {
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    const epoch = try integerField(u64, vm, -1, "epoch");
    if (epoch != snapshot.epoch()) return error.PlanEpochMismatch;
    if (try idField(wm.OutputId, vm, -1, "output") != output) return error.InvalidLayoutPlan;
    const selected = snapshot.getOutput(output) orelse return error.UnknownOutput;
    if (try idField(wm.TagId, vm, -1, "tag") != selected.active_tag) return error.InvalidLayoutPlan;
    var plans: wm.LayoutPlans = .{
        .manage = .{ .context = .{ .allocator = allocator, .epoch = epoch, .output = output } },
        .render = .{ .context = .{ .allocator = allocator, .epoch = epoch, .output = output } },
        .needs_frame = try optionalBoolField(vm, -1, "needs_frame", false),
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
        const window = try liveId(wm.WindowId, vm, snapshot, -1, "window");
        const placement = std.meta.stringToEnum(wm.Placement, try stringField(vm, -1, "state")) orelse return error.InvalidLayoutPlan;
        const screen = try rectField(vm, -1, "screen");
        plans.render.entries.appendAssumeCapacity(.{
            .window = window,
            .screen = screen,
            .clip = try rectField(vm, -1, "clip"),
            .window_clip = try optionalRectField(vm, -1, "window_clip"),
            .visible = try boolField(vm, -1, "visible"),
            .border = try optionalBorderField(vm, -1, "border"),
            .decoration_height = try optionalIntegerField(i32, vm, -1, "decoration_height", 0),
            .z_index = try optionalIntegerField(i32, vm, -1, "z", 0),
        });
        plans.manage.dimensions.appendAssumeCapacity(.{
            .window = window,
            .size = try optionalSizeField(vm, -1, "propose"),
            .placement = placement,
        });
        vm.setTop(base + 1);
    }
    vm.setTop(base);
    return plans;
}

fn liveId(comptime T: type, vm: *script.lua_vm.Vm, snapshot: *const wm.WorldView, index: c_int, comptime name: [:0]const u8) !T {
    const value = try idField(T, vm, index, name);
    const exists = if (T == wm.WindowId) snapshot.getWindow(value) != null else if (T == wm.OutputId) snapshot.getOutput(value) != null else snapshot.getTag(value) != null;
    if (!exists) return error.InvalidLayoutActionResult;
    return value;
}

fn fieldBase(vm: *script.lua_vm.Vm) c_int {
    return @intCast(vm.stackDepth());
}
fn integerField(comptime T: type, vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !T {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    return std.math.cast(T, vm.integer(-1) orelse return error.InvalidLayoutPlan) orelse error.InvalidLayoutPlan;
}
fn optionalIntegerField(comptime T: type, vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8, fallback: T) !T {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    if (vm.luaType(-1) == .nil) return fallback;
    return std.math.cast(T, vm.integer(-1) orelse return error.InvalidLayoutPlan) orelse error.InvalidLayoutPlan;
}
fn idField(comptime T: type, vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !T {
    const value: T = @bitCast(try integerField(u64, vm, index, name));
    if (!value.isValid()) return error.InvalidLayoutPlan;
    return value;
}
fn optionalIdField(comptime T: type, vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !?T {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    if (vm.luaType(-1) == .nil) return null;
    const raw = std.math.cast(u64, vm.integer(-1) orelse return error.InvalidLayoutPlan) orelse return error.InvalidLayoutPlan;
    const value: T = @bitCast(raw);
    if (!value.isValid()) return error.InvalidLayoutPlan;
    return value;
}
fn stringField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) ![]const u8 {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    return vm.string(-1) orelse error.InvalidLayoutPlan;
}
fn optionalStringField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8, fallback: []const u8) ![]const u8 {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    if (vm.luaType(-1) == .nil) return fallback;
    return vm.string(-1) orelse error.InvalidLayoutProjection;
}
const ActionArgs = struct {
    values: [script.layout_projection.max_action_args]script.layout_projection.Label = [_]script.layout_projection.Label{.{}} ** script.layout_projection.max_action_args,
    len: u8 = 0,
};
fn actionArgsField(vm: *script.lua_vm.Vm, index: c_int) !ActionArgs {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, "args");
    if (vm.luaType(-1) == .nil) return .{};
    if (vm.luaType(-1) != .table) return error.InvalidLayoutProjection;
    const count = vm.rawLength(-1);
    if (count > script.layout_projection.max_action_args) return error.InvalidLayoutProjection;
    var result: ActionArgs = .{ .len = @intCast(count) };
    const table_base: c_int = @intCast(vm.stackDepth());
    for (0..count) |arg_index| {
        vm.rawGetInteger(-1, @intCast(arg_index + 1));
        result.values[arg_index] = try script.layout_projection.Label.init(vm.string(-1) orelse return error.InvalidLayoutProjection);
        vm.setTop(table_base);
    }
    return result;
}
fn optionalBorderField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !?wm.layout.Border {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    if (vm.luaType(-1) == .nil) return null;
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    var result: wm.layout.Border = .{
        .edges = try integerField(u32, vm, -1, "edges"),
        .width = try integerField(i32, vm, -1, "width"),
    };
    vm.getField(-1, "rgba");
    if (vm.luaType(-1) != .table or vm.rawLength(-1) != result.rgba.len) return error.InvalidLayoutPlan;
    const rgba_base: c_int = @intCast(vm.stackDepth());
    for (&result.rgba, 0..) |*component, component_index| {
        vm.rawGetInteger(-1, @intCast(component_index + 1));
        component.* = std.math.cast(u32, vm.integer(-1) orelse return error.InvalidLayoutPlan) orelse return error.InvalidLayoutPlan;
        vm.setTop(rgba_base);
    }
    return result;
}
fn boolField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !bool {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    return vm.boolean(-1) orelse error.InvalidLayoutPlan;
}
fn optionalBoolField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8, fallback: bool) !bool {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    if (vm.luaType(-1) == .nil) return fallback;
    return vm.boolean(-1) orelse error.InvalidLayoutPlan;
}
fn rectField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !wm.Rect {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    return .{ .x = try integerField(i32, vm, -1, "x"), .y = try integerField(i32, vm, -1, "y"), .width = try integerField(u32, vm, -1, "width"), .height = try integerField(u32, vm, -1, "height") };
}
fn optionalRectField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !?wm.Rect {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    if (vm.luaType(-1) == .nil) return null;
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    return .{ .x = try integerField(i32, vm, -1, "x"), .y = try integerField(i32, vm, -1, "y"), .width = try integerField(u32, vm, -1, "width"), .height = try integerField(u32, vm, -1, "height") };
}
fn optionalSizeField(vm: *script.lua_vm.Vm, index: c_int, comptime name: [:0]const u8) !?wm.Size {
    const base = fieldBase(vm);
    defer vm.setTop(base);
    vm.getField(index, name);
    if (vm.luaType(-1) == .nil) return null;
    if (vm.luaType(-1) != .table) return error.InvalidLayoutPlan;
    const size: wm.Size = .{ .width = try integerField(u32, vm, -1, "width"), .height = try integerField(u32, vm, -1, "height") };
    if (size.width == 0 or size.height == 0) return error.InvalidLayoutPlan;
    return size;
}

fn setId(vm: *script.lua_vm.Vm, comptime name: [:0]const u8, value: u64) !void {
    vm.pushInteger(std.math.cast(i64, value) orelse return error.LayoutIdentityOverflow);
    vm.setField(-2, name);
}
fn setNil(vm: *script.lua_vm.Vm, comptime name: [:0]const u8) void {
    vm.pushNil();
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
fn setBool(vm: *script.lua_vm.Vm, comptime name: [:0]const u8, value: bool) void {
    vm.pushBoolean(value);
    vm.setField(-2, name);
}
fn pushRect(vm: *script.lua_vm.Vm, value: wm.Rect) void {
    vm.createTable(0, 4);
    setInteger(vm, "x", value.x);
    setInteger(vm, "y", value.y);
    setInteger(vm, "width", value.width);
    setInteger(vm, "height", value.height);
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

test "flat snapshot and per-window plan contain no layout structure" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{ .active_tag = tag, .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 }, .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 } });
    const window = try world.createWindow(.{ .tag = tag, .output = output, .transient = true });
    try world.manageWindow(window);
    var runtime = try Runtime.init(std.testing.allocator, "return { layout = function(s) assert(s.windows[1].transient); return { epoch=s.epoch, output=s.output.id, tag=s.tag.id, entries={{window=s.windows[1].id, state='tiled', screen={x=0,y=0,width=800,height=600}, clip={x=0,y=0,width=800,height=600}, visible=true, propose={width=800,height=600}}} } end }", .{});
    defer runtime.deinit();
    var snapshot = world.view();
    var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0);
    defer plans.deinit();
    try std.testing.expectEqual(window, plans.render.entries.items[0].window);
    try std.testing.expectEqual(@as(u32, 800), plans.manage.dimensions.items[0].size.?.width);
}

test "action batches commit or roll back retained provider state" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    var runtime = try Runtime.init(std.testing.allocator,
        \\local value, checkpoint = 0, nil
        \\return {
        \\  layout = function(s) return { epoch=s.epoch, output=s.output.id, tag=s.tag.id, entries={} } end,
        \\  begin_actions = function() assert(checkpoint == nil); checkpoint = value end,
        \\  action = function() value = value + 1; return {} end,
        \\  finish_actions = function(commit) if not commit then value = checkpoint end; checkpoint = nil end,
        \\  project = function() return {{ text=tostring(value) }} end,
        \\}
    , .{});
    defer runtime.deinit();
    var snapshot = world.view();
    var intents = script.IntentBatch.init(std.testing.allocator, 4);
    defer intents.deinit();

    try runtime.beginActions();
    try runtime.handleAction(&snapshot, output, "change", &.{}, &intents);
    try runtime.finishActions(false);
    var rolled_back = (try runtime.project(std.testing.allocator, &snapshot, output)).?;
    defer rolled_back.deinit();
    try std.testing.expectEqualStrings("0", rolled_back.items.items[0].text.slice());

    try runtime.beginActions();
    try runtime.handleAction(&snapshot, output, "change", &.{}, &intents);
    try runtime.finishActions(true);
    var committed = (try runtime.project(std.testing.allocator, &snapshot, output)).?;
    defer committed.deinit();
    try std.testing.expectEqualStrings("1", committed.items.items[0].text.slice());
}
