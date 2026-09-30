//! Bounded Lua execution over flat compositor facts and per-window effects.

const std = @import("std");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");

pub const Limits = struct {
    max_instructions: u64 = 2_000_000,
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

    /// The layout's own state as text, or null when nothing worth writing has
    /// changed since the last call. Costs one cheap script call when idle.
    pub fn saveState(self: *Runtime, allocator: std.mem.Allocator) !?[]u8 {
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, "save");
        if (self.vm.luaType(-1) != .function) return null;
        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, self, self.limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.call(0, 1);
        const text = self.vm.string(-1) orelse return null;
        return try allocator.dupe(u8, text);
    }

    /// Offer the layout a previous session's state. Returns whether it accepted it.
    pub fn restoreState(self: *Runtime, text: []const u8) !bool {
        defer self.vm.setTop(0);
        self.vm.getGlobal("whirlpool_layout_provider");
        if (self.vm.luaType(-1) != .table) return error.InvalidLayoutSource;
        self.vm.getField(-1, "restore");
        if (self.vm.luaType(-1) != .function) return false;
        self.vm.pushString(text);
        self.instructions = 0;
        try self.vm.setInstructionHook(instructionHook, self, self.limits.hook_granularity);
        defer self.vm.clearInstructionHook();
        try self.vm.call(1, 1);
        return self.vm.boolean(-1) orelse false;
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
        } else if (std.mem.eql(u8, name, "focus-output")) {
            const output = try liveId(wm.OutputId, vm, snapshot, -1, "output");
            try intents.append(.{ .focus_output = output });
        } else if (std.mem.eql(u8, name, "clear-focus")) {
            try intents.append(.clear_focus);
        } else if (std.mem.eql(u8, name, "close-window")) {
            const window = try liveId(wm.WindowId, vm, snapshot, -1, "window");
            try intents.append(.{ .close_window = window });
        } else if (std.mem.eql(u8, name, "move-window")) {
            const window = try liveId(wm.WindowId, vm, snapshot, -1, "window");
            const tag = try liveId(wm.TagId, vm, snapshot, -1, "tag");
            try intents.append(.{ .assign_window = .{ .window = window, .tag = tag } });
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
            .overlay = try optionalBoolField(vm, -1, "overlay", false),
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
    setBool(vm, "focused", snapshot.focusedOutput() == selected_output);
    pushRect(vm, output.bounds);
    vm.setField(-2, "bounds");
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
        setBool(vm, "focused", snapshot.focusedOutput() == id);
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
        setString(vm, "identifier", item.identifier.slice());
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
    const window = try world.createWindow(.{ .tag = tag, .transient = true });
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

test "layout projections preserve generic overlay placement" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    var runtime = try Runtime.init(std.testing.allocator,
        \\return {
        \\  layout = function(s) return { epoch=s.epoch, output=s.output.id, tag=s.tag.id, entries={} } end,
        \\  project = function() return {{ style='marker', width=3, overlay=true }} end,
        \\}
    , .{});
    defer runtime.deinit();
    var snapshot = world.view();
    var projection = (try runtime.project(std.testing.allocator, &snapshot, output)).?;
    defer projection.deinit();
    try std.testing.expect(projection.items.items[0].overlay);
    try std.testing.expectEqual(@as(u32, 3), projection.items.items[0].width);
}

const scrolling_source_path = "config/lib/scrolling.lua";

fn focusOutputTarget(
    runtime: *Runtime,
    snapshot: *const wm.WorldView,
    from: wm.OutputId,
    name: []const u8,
) !?wm.WindowId {
    var intents = script.IntentBatch.init(std.testing.allocator, 4);
    defer intents.deinit();
    try runtime.beginActions();
    errdefer runtime.finishActions(false) catch {};
    try runtime.handleAction(snapshot, from, name, &.{}, &intents);
    try runtime.finishActions(true);
    if (intents.count() == 0) return null;
    return intents.intents.items[0].focus_window;
}

test "focus-output cycles to a window shown on the destination output" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        scrolling_source_path,
        std.testing.allocator,
        .limited(script.config.MaxLayoutSourceBytes),
    );
    defer std.testing.allocator.free(source);

    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: wm.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    var outputs: [3]wm.OutputId = undefined;
    var windows: [3]wm.WindowId = undefined;
    for (&outputs, &windows) |*output, *window| {
        const tag = try world.createTag();
        output.* = try world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
        window.* = try world.createWindow(.{ .tag = tag });
        try world.manageWindow(window.*);
    }
    // A window on a tag no output shows must never be picked.
    const hidden_tag = try world.createTag();
    const hidden = try world.createWindow(.{ .tag = hidden_tag });
    try world.manageWindow(hidden);

    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    const snapshot = world.view();

    try std.testing.expectEqual(windows[1], (try focusOutputTarget(&runtime, &snapshot, outputs[0], "focus-output-next")).?);
    try std.testing.expectEqual(windows[2], (try focusOutputTarget(&runtime, &snapshot, outputs[1], "focus-output-next")).?);
    try std.testing.expectEqual(windows[0], (try focusOutputTarget(&runtime, &snapshot, outputs[2], "focus-output-next")).?);
    try std.testing.expectEqual(windows[2], (try focusOutputTarget(&runtime, &snapshot, outputs[0], "focus-output-prev")).?);
}

test "focus-output does nothing with a single output" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        scrolling_source_path,
        std.testing.allocator,
        .limited(script.config.MaxLayoutSourceBytes),
    );
    defer std.testing.allocator.free(source);

    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: wm.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const tag = try world.createTag();
    const output = try world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
    const window = try world.createWindow(.{ .tag = tag });
    try world.manageWindow(window);

    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    const snapshot = world.view();
    try std.testing.expectEqual(@as(?wm.WindowId, null), try focusOutputTarget(&runtime, &snapshot, output, "focus-output-next"));
}

const Round = struct {
    sizes: [8]?wm.Size = .{null} ** 8,
    screens: [8]wm.Rect = .{std.mem.zeroes(wm.Rect)} ** 8,
    len: usize = 0,

    fn eql(a: Round, b: Round) bool {
        if (a.len != b.len) return false;
        for (0..a.len) |i| {
            if (!std.meta.eql(a.sizes[i], b.sizes[i])) return false;
            if (!std.meta.eql(a.screens[i], b.screens[i])) return false;
        }
        return true;
    }
};

/// One compositor round: lay out every output, then let every client answer
/// with a size snapped to its terminal cell grid (as a real terminal does).
fn layoutRound(world: *wm.World, runtime: *Runtime, outputs: []const wm.OutputId) !Round {
    var round: Round = .{};
    var updates: [8]struct { window: wm.WindowId, size: wm.Size } = undefined;
    var update_count: usize = 0;
    const snapshot = world.view();
    for (outputs) |output| {
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0);
        defer plans.deinit();
        for (plans.manage.dimensions.items) |proposal| {
            const size = proposal.size orelse continue;
            round.sizes[round.len] = size;
            updates[update_count] = .{
                .window = proposal.window,
                .size = .{ .width = @max(10, size.width / 10 * 10), .height = @max(20, size.height / 20 * 20) },
            };
            update_count += 1;
            round.len += 1;
        }
        for (plans.render.entries.items, round.len - plans.manage.dimensions.items.len..) |entry, i| {
            if (i < round.len) round.screens[i] = entry.screen;
        }
    }
    for (updates[0..update_count]) |update| {
        _ = try world.applyAtomically(&.{.{ .window = .{ .update_sizing = .{
            .window = update.window,
            .hints = .{},
            .actual = update.size,
            .proposed = null,
        } } }});
    }
    return round;
}

test "layout reaches a fixed point when clients snap to a cell grid" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        scrolling_source_path,
        std.testing.allocator,
        .limited(script.config.MaxLayoutSourceBytes),
    );
    defer std.testing.allocator.free(source);

    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const modes = [_]wm.Size{
        .{ .width = 2560, .height = 1440 },
        .{ .width = 1920, .height = 1080 },
        .{ .width = 3440, .height = 1440 },
    };
    const window_counts = [_]usize{ 2, 1, 3 };
    var outputs: [3]wm.OutputId = undefined;
    for (&outputs, modes, window_counts) |*output, mode, count| {
        const tag = try world.createTag();
        const rect: wm.Rect = .{ .x = 0, .y = 0, .width = mode.width, .height = mode.height };
        output.* = try world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
        for (0..count) |_| {
            const window = try world.createWindow(.{ .tag = tag });
            try world.manageWindow(window);
        }
    }

    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();

    var previous = try layoutRound(&world, &runtime, &outputs);
    var stable_rounds: usize = 0;
    for (0..12) |_| {
        const current = try layoutRound(&world, &runtime, &outputs);
        stable_rounds = if (current.eql(previous)) stable_rounds + 1 else 0;
        previous = current;
    }
    // A resize loop shows up as proposals or geometry that keep changing.
    try std.testing.expect(stable_rounds >= 6);
}

/// Dispatch a layout action exactly as the host does: on the focused window's
/// output, applying the resulting intents to the world, then relayout.
fn dispatchAction(world: *wm.World, runtime: *Runtime, outputs: []const wm.OutputId, name: []const u8) !void {
    var snapshot = world.view();
    const output = snapshot.focusedOutput() orelse return error.NothingFocused;
    var intents = script.IntentBatch.init(std.testing.allocator, 8);
    defer intents.deinit();
    try runtime.beginActions();
    errdefer runtime.finishActions(false) catch {};
    try runtime.handleAction(&snapshot, output, name, &.{}, &intents);
    try runtime.finishActions(true);
    for (intents.intents.items) |intent| _ = try world.applyAtomically(&.{intent.toCommand()});
    _ = try layoutRound(world, runtime, outputs);
}

fn focusedOutputIndex(world: *const wm.World, outputs: []const wm.OutputId) !usize {
    const output = world.focusedOutput() orelse return error.NothingFocused;
    for (outputs, 0..) |candidate, index| if (candidate == output) return index;
    return error.UnknownOutput;
}

test "repeated focus-output steps through every output, with layout between" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        scrolling_source_path,
        std.testing.allocator,
        .limited(script.config.MaxLayoutSourceBytes),
    );
    defer std.testing.allocator.free(source);

    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const modes = [_]wm.Size{
        .{ .width = 2560, .height = 1440 },
        .{ .width = 1920, .height = 1080 },
        .{ .width = 3440, .height = 1440 },
    };
    const window_counts = [_]usize{ 2, 1, 3 };
    var outputs: [3]wm.OutputId = undefined;
    var first_window: wm.WindowId = undefined;
    for (&outputs, modes, window_counts, 0..) |*output, mode, count, index| {
        const tag = try world.createTag();
        const rect: wm.Rect = .{ .x = 0, .y = 0, .width = mode.width, .height = mode.height };
        output.* = try world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
        for (0..count) |n| {
            const window = try world.createWindow(.{ .tag = tag });
            try world.manageWindow(window);
            if (index == 0 and n == 0) first_window = window;
        }
    }
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = first_window } }});

    var runtime = try Runtime.init(std.testing.allocator, source, .{});
    defer runtime.deinit();
    _ = try layoutRound(&world, &runtime, &outputs);

    var expected: usize = 0;
    for (0..7) |_| {
        try dispatchAction(&world, &runtime, &outputs, "focus-output-next");
        expected = (expected + 1) % outputs.len;
        try std.testing.expectEqual(expected, try focusedOutputIndex(&world, &outputs));
    }
    for (0..7) |_| {
        try dispatchAction(&world, &runtime, &outputs, "focus-output-prev");
        expected = (expected + outputs.len - 1) % outputs.len;
        try std.testing.expectEqual(expected, try focusedOutputIndex(&world, &outputs));
    }
}

const Desk = struct {
    world: wm.World,
    outputs: [3]wm.OutputId,
    tags: [3]wm.TagId,
    windows: [3]wm.WindowId,

    /// One window per output, all unpinned: they follow their tag, as windows
    /// moved with send-to-tag do.
    fn unpinned(desk: *Desk) !void {
        desk.world = wm.World.init(std.testing.allocator);
        for (&desk.outputs, &desk.tags, &desk.windows, 0..) |*output, *tag, *window, index| {
            const rect: wm.Rect = .{ .x = @intCast(index * 1280), .y = 0, .width = 1280, .height = 720 };
            tag.* = try desk.world.createTag();
            output.* = try desk.world.createOutput(.{ .active_tag = tag.*, .bounds = rect, .usable = rect });
            window.* = try desk.world.createWindow(.{ .tag = tag.* });
            try desk.world.manageWindow(window.*);
        }
        _ = try desk.world.applyAtomically(&.{.{ .focus = .{ .window = desk.windows[0] } }});
    }
};

fn scrollingRuntime() !struct { source: []u8, runtime: Runtime } {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        scrolling_source_path,
        std.testing.allocator,
        .limited(script.config.MaxLayoutSourceBytes),
    );
    errdefer std.testing.allocator.free(source);
    return .{ .source = source, .runtime = try Runtime.init(std.testing.allocator, source, .{}) };
}

test "focus-output steps through every output when windows are unpinned" {
    var desk: Desk = undefined;
    try desk.unpinned();
    defer desk.world.deinit();
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    _ = try layoutRound(&desk.world, &fixture.runtime, &desk.outputs);

    var expected: usize = 0;
    for (0..7) |_| {
        try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-output-next");
        expected = (expected + 1) % 3;
        try std.testing.expectEqual(expected, try focusedOutputIndex(&desk.world, &desk.outputs));
    }
    for (0..7) |_| {
        try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-output-prev");
        expected = (expected + 2) % 3;
        try std.testing.expectEqual(expected, try focusedOutputIndex(&desk.world, &desk.outputs));
    }
}

test "focus-tag on a tag another output shows only moves focus" {
    var desk: Desk = undefined;
    try desk.unpinned();
    defer desk.world.deinit();
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    _ = try layoutRound(&desk.world, &fixture.runtime, &desk.outputs);

    // Tag 3 ordinal is shown on output 3: focus goes there and nothing moves.
    var snapshot = desk.world.view();
    var intents = script.IntentBatch.init(std.testing.allocator, 8);
    defer intents.deinit();
    try fixture.runtime.beginActions();
    try fixture.runtime.handleAction(&snapshot, desk.outputs[0], "focus-tag", &.{"3"}, &intents);
    try fixture.runtime.finishActions(true);
    try std.testing.expectEqual(@as(usize, 1), intents.count());
    try std.testing.expectEqual(desk.windows[2], intents.intents.items[0].focus_window);

    // A tag no output shows is switched to normally.
    const hidden = try desk.world.createTag();
    var hidden_snapshot = desk.world.view();
    intents.clear();
    try fixture.runtime.beginActions();
    try fixture.runtime.handleAction(&hidden_snapshot, desk.outputs[0], "focus-tag", &.{"4"}, &intents);
    try fixture.runtime.finishActions(true);
    try std.testing.expect(intents.count() >= 1);
    switch (intents.intents.items[0]) {
        .set_active_tag => |value| {
            try std.testing.expectEqual(desk.outputs[0], value.output);
            try std.testing.expectEqual(hidden, value.tag);
        },
        else => return error.ExpectedSetActiveTag,
    }
}

test "focus-tag reaches a tag shown on any other output, from any output" {
    var desk: Desk = undefined;
    try desk.unpinned();
    defer desk.world.deinit();
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    _ = try layoutRound(&desk.world, &fixture.runtime, &desk.outputs);

    var intents = script.IntentBatch.init(std.testing.allocator, 8);
    defer intents.deinit();
    for (desk.outputs, 0..) |from, from_index| for (desk.windows, 0..) |window, tag_index| {
        if (from_index == tag_index) continue;
        const snapshot = desk.world.view();
        intents.clear();
        var ordinal: [1]u8 = .{@intCast('1' + tag_index)};
        try fixture.runtime.beginActions();
        try fixture.runtime.handleAction(&snapshot, from, "focus-tag", &.{&ordinal}, &intents);
        try fixture.runtime.finishActions(true);
        try std.testing.expectEqual(@as(usize, 1), intents.count());
        try std.testing.expectEqual(window, intents.intents.items[0].focus_window);
    };
}

/// Windows on monitors 1 and 3; monitor 2 is empty. Focus starts on monitor 1.
fn gappedDesk(desk: *Desk) !void {
    try desk.unpinned();
    _ = try desk.world.applyAtomically(&.{.{ .window = .{ .destroy = desk.windows[1] } }});
}

test "an empty monitor can be focused, and focus continues past it" {
    var desk: Desk = undefined;
    try gappedDesk(&desk);
    defer desk.world.deinit();
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    _ = try layoutRound(&desk.world, &fixture.runtime, &desk.outputs);

    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-output-next");
    try std.testing.expectEqual(@as(usize, 1), try focusedOutputIndex(&desk.world, &desk.outputs));
    try std.testing.expectEqual(@as(?wm.WindowId, null), desk.world.focusedWindow());

    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-output-next");
    try std.testing.expectEqual(@as(usize, 2), try focusedOutputIndex(&desk.world, &desk.outputs));
    try std.testing.expectEqual(@as(?wm.WindowId, desk.windows[2]), desk.world.focusedWindow());

    // Backwards, through the empty monitor again.
    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-output-prev");
    try std.testing.expectEqual(@as(usize, 1), try focusedOutputIndex(&desk.world, &desk.outputs));
    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-output-prev");
    try std.testing.expectEqual(@as(?wm.WindowId, desk.windows[0]), desk.world.focusedWindow());
}

test "focusing past a monitor's edge continues onto the neighbouring monitor" {
    var desk: Desk = undefined;
    try gappedDesk(&desk);
    defer desk.world.deinit();
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    _ = try layoutRound(&desk.world, &fixture.runtime, &desk.outputs);

    // Left of the leftmost monitor there is nothing to focus.
    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-left");
    try std.testing.expectEqual(@as(usize, 0), try focusedOutputIndex(&desk.world, &desk.outputs));

    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-right");
    try std.testing.expectEqual(@as(usize, 1), try focusedOutputIndex(&desk.world, &desk.outputs));
    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-right");
    try std.testing.expectEqual(@as(?wm.WindowId, desk.windows[2]), desk.world.focusedWindow());
    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-right");
    try std.testing.expectEqual(@as(usize, 2), try focusedOutputIndex(&desk.world, &desk.outputs));
    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-left");
    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-left");
    try std.testing.expectEqual(@as(?wm.WindowId, desk.windows[0]), desk.world.focusedWindow());
}

test "actions run on the focused monitor even when it has no window" {
    var desk: Desk = undefined;
    try gappedDesk(&desk);
    defer desk.world.deinit();
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    _ = try layoutRound(&desk.world, &fixture.runtime, &desk.outputs);
    try dispatchAction(&desk.world, &fixture.runtime, &desk.outputs, "focus-output-next");

    // Asking for tag 3 from empty monitor 2 finds it on monitor 3 and focuses it.
    var snapshot = desk.world.view();
    var intents = script.IntentBatch.init(std.testing.allocator, 8);
    defer intents.deinit();
    try fixture.runtime.beginActions();
    try fixture.runtime.handleAction(&snapshot, snapshot.focusedOutput().?, "focus-tag", &.{"3"}, &intents);
    try fixture.runtime.finishActions(true);
    try std.testing.expectEqual(@as(usize, 1), intents.count());
    try std.testing.expectEqual(desk.windows[2], intents.intents.items[0].focus_window);
}

test "windows entirely past a monitor's edge are hidden, not drawn on its neighbour" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: wm.Rect = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    const tag = try world.createTag();
    const output = try world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
    for (0..6) |_| {
        const window = try world.createWindow(.{ .tag = tag });
        try world.manageWindow(window);
    }
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    const outputs = [_]wm.OutputId{output};
    for (0..3) |_| _ = try layoutRound(&world, &fixture.runtime, &outputs);

    const snapshot = world.view();
    var plans = try fixture.runtime.buildAt(std.testing.allocator, &snapshot, output, 0);
    defer plans.deinit();
    var hidden: usize = 0;
    var shown: usize = 0;
    for (plans.render.entries.items) |entry| {
        if (entry.visible) {
            shown += 1;
            // An empty clip box means "no clip" to River, so it must never
            // accompany a visible window.
            try std.testing.expect(entry.clip.width > 0 and entry.clip.height > 0);
            try std.testing.expect(entry.screen.x < @as(i32, @intCast(rect.width)) and entry.screen.x + @as(i32, @intCast(entry.screen.width)) > 0);
        } else {
            hidden += 1;
        }
    }
    try std.testing.expect(shown >= 1);
    try std.testing.expect(hidden >= 1);
}

/// Lua VM instructions one layout call runs for `count` tiled windows, once the
/// model has settled.
fn layoutInstructions(count: usize) !u64 {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        scrolling_source_path,
        std.testing.allocator,
        .limited(script.config.MaxLayoutSourceBytes),
    );
    defer std.testing.allocator.free(source);
    // A generous budget: this measures the work, not the safety limit.
    var runtime = try Runtime.init(std.testing.allocator, source, .{ .max_instructions = 2_000_000_000, .max_entries = 100_000 });
    defer runtime.deinit();
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: wm.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const tag = try world.createTag();
    const output = try world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
    for (0..count) |_| {
        const window = try world.createWindow(.{ .tag = tag });
        try world.manageWindow(window);
    }
    const snapshot = world.view();
    for (0..3) |_| {
        var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0);
        plans.deinit();
    }
    var plans = try runtime.buildAt(std.testing.allocator, &snapshot, output, 0);
    plans.deinit();
    return runtime.instructions;
}

test "layout work grows in proportion to the windows, not their square" {
    // Deterministic: Lua VM instructions, not wall time. Quadrupling the
    // windows should roughly quadruple the work; a scan of every strip per
    // window would make it sixteen times.
    const small = try layoutInstructions(100);
    const large = try layoutInstructions(400);
    try std.testing.expect(small > 0);
    try std.testing.expect(large < small * 5);
}

test "a few hundred windows fit the default instruction budget" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: wm.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const tag = try world.createTag();
    const output = try world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
    for (0..300) |_| {
        const window = try world.createWindow(.{ .tag = tag });
        try world.manageWindow(window);
    }
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    const snapshot = world.view();
    for (0..3) |_| {
        var plans = try fixture.runtime.buildAt(std.testing.allocator, &snapshot, output, 0);
        plans.deinit();
    }
}

fn sameSizes(a: Round, b: Round) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (!std.meta.eql(a.sizes[i], b.sizes[i])) return false;
    return true;
}

const Lone = struct {
    world: wm.World,
    output: [1]wm.OutputId,
    windows: [3]wm.WindowId,

    fn init(lone: *Lone) !void {
        lone.world = wm.World.init(std.testing.allocator);
        const rect: wm.Rect = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
        const tag = try lone.world.createTag();
        lone.output[0] = try lone.world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
        const names = [_][]const u8{ "alpha", "beta", "gamma" };
        for (&lone.windows, names) |*window, name| {
            window.* = try lone.world.createWindow(.{ .tag = tag, .identifier = wm.Identifier.init(name) });
            try lone.world.manageWindow(window.*);
        }
        _ = try lone.world.applyAtomically(&.{.{ .focus = .{ .window = lone.windows[1] } }});
    }
};

test "layout state saved by one runtime rebuilds the same arrangement in another" {
    var first: Lone = undefined;
    try first.init();
    defer first.world.deinit();
    var one = try scrollingRuntime();
    defer std.testing.allocator.free(one.source);
    defer one.runtime.deinit();
    _ = try layoutRound(&first.world, &one.runtime, &first.output);
    try dispatchAction(&first.world, &one.runtime, &first.output, "absorb-right");
    _ = try layoutRound(&first.world, &one.runtime, &first.output);
    const arranged = try layoutRound(&first.world, &one.runtime, &first.output);

    const text = (try one.runtime.saveState(std.testing.allocator)) orelse return error.ExpectedState;
    defer std.testing.allocator.free(text);
    // Nothing has changed since: nothing to write.
    try std.testing.expectEqual(@as(?[]u8, null), try one.runtime.saveState(std.testing.allocator));

    // A new process, a new world whose windows have new ids but the same identifiers.
    var second: Lone = undefined;
    try second.init();
    defer second.world.deinit();
    var two = try scrollingRuntime();
    defer std.testing.allocator.free(two.source);
    defer two.runtime.deinit();
    try std.testing.expect(try two.runtime.restoreState(text));
    _ = try layoutRound(&second.world, &two.runtime, &second.output);
    _ = try layoutRound(&second.world, &two.runtime, &second.output);
    const restored = try layoutRound(&second.world, &two.runtime, &second.output);
    // Positions animate from where windows were (time stands still in a test), so
    // compare the sizes the arrangement asks for.
    try std.testing.expect(sameSizes(restored, arranged));

    // Without the saved state the same windows are laid out differently.
    var third: Lone = undefined;
    try third.init();
    defer third.world.deinit();
    var three = try scrollingRuntime();
    defer std.testing.allocator.free(three.source);
    defer three.runtime.deinit();
    _ = try layoutRound(&third.world, &three.runtime, &third.output);
    _ = try layoutRound(&third.world, &three.runtime, &third.output);
    const fresh = try layoutRound(&third.world, &three.runtime, &third.output);
    try std.testing.expect(!sameSizes(fresh, arranged));
}

test "damaged or foreign layout state is refused and changes nothing" {
    const junk = [_][]const u8{ "", "not lua at all (", "return 42", "return { version = 99 }", "os.exit(1)", "error('boom')" };
    for (junk) |text| {
        var lone: Lone = undefined;
        try lone.init();
        defer lone.world.deinit();
        var fixture = try scrollingRuntime();
        defer std.testing.allocator.free(fixture.source);
        defer fixture.runtime.deinit();
        const accepted = fixture.runtime.restoreState(text) catch false;
        try std.testing.expect(!accepted);
        const round = try layoutRound(&lone.world, &fixture.runtime, &lone.output);
        try std.testing.expectEqual(@as(usize, 3), round.len);
    }
}

const hostile_layouts = [_][]const u8{
    // Not JSON: nothing is evaluated, all of it is refused.
    "local t = {} t[1] = t return {version = 1, tags = t}",
    "while true do end",
    "return (\"x\"):rep(1e10)",
    "{\"version\":1,\"tags\":[",
    "{\"version\":1} trailing",
    "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[",
    // Well-formed, but the wrong shape.
    "{\"version\":1,\"tags\":5}",
    "{\"version\":1,\"tags\":[5,null,\"x\",[]]}",
    "{\"version\":1,\"tags\":[{\"ordinal\":1,\"strips\":7}]}",
    "{\"version\":1,\"tags\":[{\"ordinal\":1,\"strips\":[5,{\"roots\":3}]}]}",
    "{\"version\":1,\"tags\":[{\"ordinal\":1,\"strips\":[{\"roots\":[{\"node\":4}]}]}]}",
    "{\"version\":1,\"states\":3,\"marks\":4}",
    // Numbers that would poison geometry.
    "{\"version\":1,\"tags\":[{\"ordinal\":1,\"strips\":[{\"roots\":[{\"width\":1e999,\"node\":{\"mode\":\"x\",\"axis\":1,\"active\":2.5,\"children\":[{\"weight\":-1,\"node\":{\"window\":\"alpha\"}},{\"weight\":1e999,\"node\":{\"window\":\"beta\"}}]}}]}]}]}",
    "{\"version\":1,\"tags\":[{\"ordinal\":1,\"strips\":[{\"roots\":[{\"width\":-5,\"node\":{\"children\":[{\"weight\":0,\"node\":{\"window\":\"alpha\"}},{\"weight\":0,\"node\":{\"window\":\"beta\"}}]}}]}]}]}",
    // The same window in many places.
    "{\"version\":1,\"tags\":[{\"ordinal\":1,\"strips\":[{\"roots\":[{\"node\":{\"window\":\"alpha\"}},{\"node\":{\"window\":\"alpha\"}},{\"node\":{\"children\":[{\"node\":{\"window\":\"alpha\"}},{\"node\":{\"window\":\"alpha\"}}]}}]}]}]}",
    // Wrong tags, unknown states, silly ordinals.
    "{\"version\":1,\"tags\":[{\"ordinal\":2,\"strips\":[{\"roots\":[{\"node\":{\"window\":\"alpha\",\"state\":\"bogus\"}}]}]}],\"states\":{\"alpha\":\"bogus\"}}",
    "{\"version\":1,\"tags\":[{\"ordinal\":1e9},{\"ordinal\":-1},{\"ordinal\":0.5},{\"ordinal\":\"1\"}]}",
};

test "hostile layout state never breaks layout" {
    for (hostile_layouts, 0..) |text, case| {
        errdefer std.debug.print("hostile case {d}\n", .{case});
        var lone: Lone = undefined;
        try lone.init();
        defer lone.world.deinit();
        var fixture = try scrollingRuntime();
        defer std.testing.allocator.free(fixture.source);
        defer fixture.runtime.deinit();
        _ = fixture.runtime.restoreState(text) catch false;
        // Several rounds, and actions, must all still work and place every window.
        var round: Round = .{};
        for (0..3) |_| round = try layoutRound(&lone.world, &fixture.runtime, &lone.output);
        try dispatchAction(&lone.world, &fixture.runtime, &lone.output, "focus-right");
        try dispatchAction(&lone.world, &fixture.runtime, &lone.output, "absorb-left");
        round = try layoutRound(&lone.world, &fixture.runtime, &lone.output);
        try std.testing.expectEqual(@as(usize, 3), round.len);
        for (round.sizes[0..round.len]) |size| {
            try std.testing.expect(size != null and size.?.width > 0 and size.?.height > 0);
        }
    }
}

test "the parts of a damaged file that make sense are still applied" {
    // Tag 1 is good: beta over gamma beside alpha. Tag 2 is garbage, and so is a
    // stray root inside tag 1.
    const text =
        \\{"version":1,"tags":[
        \\ {"ordinal":1,"strips":[{"roots":[
        \\   {"width":0.5,"node":{"window":"alpha"}},
        \\   "garbage",
        \\   {"width":0.5,"node":{"mode":"split","axis":"vertical","active":1,"children":[
        \\      {"weight":1,"node":{"window":"beta"}},{"weight":1,"node":{"window":"gamma"}}]}}]}]},
        \\ {"ordinal":2,"strips":"nonsense"}, 17]}
    ;
    var lone: Lone = undefined;
    try lone.init();
    defer lone.world.deinit();
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    try std.testing.expect(try fixture.runtime.restoreState(text));
    var round: Round = .{};
    for (0..3) |_| round = try layoutRound(&lone.world, &fixture.runtime, &lone.output);
    // alpha full height beside a stacked pair: the same sizes as the round-trip test.
    try std.testing.expectEqual(@as(usize, 3), round.len);
    try std.testing.expect(round.sizes[0].?.height > round.sizes[1].?.height);
    try std.testing.expectEqual(round.sizes[1].?.height, round.sizes[2].?.height);
}

test "fields the layout gains later are saved and restored without the persistence code knowing them" {
    const text =
        \\{"version":1,"tags":[{"ordinal":1,"strips":[{"roots":[
        \\  {"width":0.5,"sticky":true,"node":{"window":"alpha","note":"hello"}},
        \\  {"width":0.5,"node":{"mode":"split","axis":"vertical","active":1,"colour":7,"children":[
        \\     {"weight":1,"pinned":true,"node":{"window":"beta"}},{"weight":1,"node":{"window":"gamma"}}]}}]}]}]}
    ;
    var lone: Lone = undefined;
    try lone.init();
    defer lone.world.deinit();
    var fixture = try scrollingRuntime();
    defer std.testing.allocator.free(fixture.source);
    defer fixture.runtime.deinit();
    try std.testing.expect(try fixture.runtime.restoreState(text));
    _ = try layoutRound(&lone.world, &fixture.runtime, &lone.output);
    const saved = (try fixture.runtime.saveState(std.testing.allocator)) orelse return error.ExpectedState;
    defer std.testing.allocator.free(saved);
    for ([_][]const u8{ "\"sticky\":true", "\"note\":\"hello\"", "\"colour\":7", "\"pinned\":true" }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, saved, field) != null);
    }
}
