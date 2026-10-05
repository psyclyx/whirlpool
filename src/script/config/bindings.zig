//! Owned key bindings and the Lua-to-native action vocabulary.

const std = @import("std");
const lua_vm = @import("../lua_vm.zig");

pub const MaxBindings: usize = 512;
pub const MaxArguments: usize = 16;
pub const MaxModeBytes: usize = 32;
pub const default_mode = "default";

pub const LayoutAction = struct {
    name: []u8,
    args: [][]u8,

    pub fn deinit(self: *LayoutAction, allocator: std.mem.Allocator) void {
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Action = union(enum) {
    layout: LayoutAction,
    /// From a pointer binding: hand the pointer to River until the button is
    /// released, telling the layout action of the motion as the window under
    /// the pointer is dragged (see `surface.act("pointer-operation", ...)`).
    pointer_operation: LayoutAction,
    enter_mode: []u8,
    spawn: [][]u8,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .layout, .pointer_operation => |*value| value.deinit(allocator),
            .enter_mode => |mode| allocator.free(mode),
            .spawn => |args| {
                for (args) |arg| allocator.free(arg);
                allocator.free(args);
            },
        }
        self.* = undefined;
    }
};

pub const Binding = struct {
    key: []u8,
    mode: []u8,
    /// A key's, or 0 for a pointer button (`button`, from `pointer:left`,
    /// `pointer:middle`, `pointer:right`).
    keysym: u32,
    modifiers: u32,
    action: Action,
    button: u32 = 0,

    pub fn deinit(self: *Binding, allocator: std.mem.Allocator) void {
        self.action.deinit(allocator);
        allocator.free(self.mode);
        allocator.free(self.key);
        self.* = undefined;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidBindings,
    InvalidBinding,
    InvalidAction,
    InvalidModifiers,
    InvalidMode,
    InvalidKey,
    TooManyBindings,
    TooManyArguments,
    DuplicateBinding,
};

pub fn parse(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error![]Binding {
    if (vm.luaType(-1) != .table) return error.InvalidBindings;
    const base: c_int = @intCast(vm.stackDepth());
    const count = vm.rawLength(-1);
    if (count > MaxBindings) return error.TooManyBindings;

    const result = try allocator.alloc(Binding, count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*binding| binding.deinit(allocator);
        allocator.free(result);
    }
    while (initialized < count) : (initialized += 1) {
        vm.rawGetInteger(-1, @intCast(initialized + 1));
        result[initialized] = try parseOne(allocator, vm);
        vm.setTop(base);
        for (result[0..initialized]) |previous| {
            if (std.mem.eql(u8, previous.mode, result[initialized].mode) and
                previous.keysym == result[initialized].keysym and
                previous.button == result[initialized].button and
                previous.modifiers == result[initialized].modifiers)
                return error.DuplicateBinding;
        }
    }
    return result;
}

fn parseOne(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error!Binding {
    if (vm.luaType(-1) != .table) return error.InvalidBinding;
    const base: c_int = @intCast(vm.stackDepth());

    vm.getField(-1, "key");
    const key_name = vm.string(-1) orelse return error.InvalidKey;
    const key = try allocator.dupe(u8, key_name);
    errdefer allocator.free(key);
    vm.setTop(base);
    const button = pointerButton(key);
    const keysym = if (button != null) 0 else keyToKeysym(key) orelse return error.InvalidKey;

    vm.getField(-1, "mode");
    const mode_name = if (vm.luaType(-1) == .nil) default_mode else vm.string(-1) orelse return error.InvalidMode;
    if (mode_name.len == 0 or mode_name.len > MaxModeBytes) return error.InvalidMode;
    const mode = try allocator.dupe(u8, mode_name);
    errdefer allocator.free(mode);
    vm.setTop(base);

    var modifiers: u32 = 0;
    vm.getField(-1, "modifiers");
    if (vm.luaType(-1) == .table) {
        const count = vm.rawLength(-1);
        if (count > 8) return error.InvalidModifiers;
        for (0..count) |index| {
            vm.rawGetInteger(-1, @intCast(index + 1));
            const modifier = vm.string(-1) orelse return error.InvalidModifiers;
            modifiers |= modifierBits(modifier) orelse return error.InvalidModifiers;
            vm.setTop(base + 1);
        }
    } else if (vm.luaType(-1) != .nil) return error.InvalidModifiers;
    vm.setTop(base);

    vm.getField(-1, "action");
    var action = try parseAction(allocator, vm);
    vm.setTop(base);
    errdefer action.deinit(allocator);
    if (action == .pointer_operation and button == null) return error.InvalidAction;
    return .{ .key = key, .mode = mode, .keysym = keysym, .modifiers = modifiers, .action = action, .button = button orelse 0 };
}

fn parseAction(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error!Action {
    if (vm.luaType(-1) != .table) return error.InvalidAction;
    const base: c_int = @intCast(vm.stackDepth());
    vm.getField(-1, "name");
    const name = vm.string(-1) orelse return error.InvalidAction;
    vm.setTop(base);

    vm.getField(-1, "args");
    const count = if (vm.luaType(-1) == .table) vm.rawLength(-1) else 0;
    if (count > MaxArguments) return error.TooManyArguments;
    if (std.mem.eql(u8, name, "spawn")) {
        if (count == 0) return error.InvalidAction;
        return .{ .spawn = try parseStringArguments(allocator, vm, base, count) };
    }
    if (std.mem.eql(u8, name, "enter-mode"))
        return .{ .enter_mode = try parseSingleStringArgument(allocator, vm, base, count) };
    if (std.mem.eql(u8, name, "layout"))
        return .{ .layout = try parseLayoutAction(allocator, vm, base, count) };
    if (std.mem.eql(u8, name, "pointer-operation"))
        return .{ .pointer_operation = try parseLayoutAction(allocator, vm, base, count) };
    return error.InvalidAction;
}

fn parseLayoutAction(
    allocator: std.mem.Allocator,
    vm: *lua_vm.Vm,
    base: c_int,
    count: usize,
) Error!LayoutAction {
    if (count == 0) return error.InvalidAction;
    const values = try parseStringArguments(allocator, vm, base, count);
    errdefer {
        for (values) |value| allocator.free(value);
        allocator.free(values);
    }
    const args = try allocator.alloc([]u8, count - 1);
    @memcpy(args, values[1..]);
    const name = values[0];
    allocator.free(values);
    return .{ .name = name, .args = args };
}

fn parseSingleStringArgument(
    allocator: std.mem.Allocator,
    vm: *lua_vm.Vm,
    base: c_int,
    count: usize,
) Error![]u8 {
    if (count != 1) return error.InvalidAction;
    vm.rawGetInteger(-1, 1);
    defer vm.setTop(base + 1);
    const value = vm.string(-1) orelse return error.InvalidAction;
    if (value.len == 0 or value.len > MaxModeBytes) return error.InvalidMode;
    return allocator.dupe(u8, value);
}

fn parseStringArguments(allocator: std.mem.Allocator, vm: *lua_vm.Vm, base: c_int, count: usize) Error![][]u8 {
    const args = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (args[0..initialized]) |arg| allocator.free(arg);
        allocator.free(args);
    }
    while (initialized < count) : (initialized += 1) {
        vm.rawGetInteger(-1, @intCast(initialized + 1));
        const value = vm.string(-1) orelse return error.InvalidAction;
        args[initialized] = try allocator.dupe(u8, value);
        vm.setTop(base + 1);
    }
    return args;
}

fn modifierBits(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "shift")) return 1;
    if (std.mem.eql(u8, name, "ctrl")) return 4;
    if (std.mem.eql(u8, name, "alt") or std.mem.eql(u8, name, "mod1")) return 8;
    if (std.mem.eql(u8, name, "super") or std.mem.eql(u8, name, "mod4")) return 64;
    if (std.mem.eql(u8, name, "mod3")) return 32;
    if (std.mem.eql(u8, name, "mod5")) return 128;
    if (std.mem.eql(u8, name, "none")) return 0;
    return null;
}

/// linux/input-event-codes.h buttons, for keys `pointer:<name>`.
fn pointerButton(key: []const u8) ?u32 {
    const prefix = "pointer:";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const buttons = std.StaticStringMap(u32).initComptime(.{
        .{ "left", 0x110 }, .{ "right", 0x111 }, .{ "middle", 0x112 },
    });
    return buttons.get(key[prefix.len..]);
}

fn keyToKeysym(key: []const u8) ?u32 {
    if (key.len == 1) return key[0];
    const named = std.StaticStringMap(u32).initComptime(.{
        .{ "Return", 0xff0d },                   .{ "Tab", 0xff09 },               .{ "Escape", 0xff1b },
        .{ "space", 0x20 },                      .{ "comma", ',' },                .{ "period", '.' },
        .{ "slash", '/' },                       .{ "Left", 0xff51 },              .{ "Up", 0xff52 },
        .{ "Right", 0xff53 },                    .{ "Down", 0xff54 },              .{ "XF86AudioRaiseVolume", 0x1008ff13 },
        .{ "XF86AudioLowerVolume", 0x1008ff11 }, .{ "XF86AudioMute", 0x1008ff12 }, .{ "XF86AudioPlay", 0x1008ff14 },
        .{ "XF86AudioNext", 0x1008ff17 },        .{ "XF86AudioPrev", 0x1008ff16 }, .{ "XF86AudioStop", 0x1008ff15 },
    });
    return named.get(key);
}

test "directional layout actions cross the config boundary opaquely" {
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try vm.evalValue(
        "return {{ key = 'j', modifiers = {'alt'}, " ++
            "action = { name = 'layout', args = {'focus-down', 'kept-verbatim'} } }}",
        "=bindings-test",
    );
    const bindings = try parse(std.testing.allocator, &vm);
    defer {
        for (bindings) |*binding| binding.deinit(std.testing.allocator);
        std.testing.allocator.free(bindings);
    }
    switch (bindings[0].action) {
        .layout => |value| {
            try std.testing.expectEqualStrings("focus-down", value.name);
            try std.testing.expectEqual(@as(usize, 1), value.args.len);
            try std.testing.expectEqualStrings("kept-verbatim", value.args[0]);
        },
        else => return error.ExpectedLayoutAction,
    }
}

test "modal structural actions retain letter marks and named escape keys" {
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try vm.evalValue(
        "return {{ mode = 'mark', key = 'Escape', " ++
            "action = { name = 'layout', args = {'mark', 'a'} } }}",
        "=structural-bindings-test",
    );
    const bindings = try parse(std.testing.allocator, &vm);
    defer {
        for (bindings) |*binding| binding.deinit(std.testing.allocator);
        std.testing.allocator.free(bindings);
    }
    try std.testing.expectEqual(@as(u32, 0xff1b), bindings[0].keysym);
    try std.testing.expectEqualStrings("mark", bindings[0].mode);
    switch (bindings[0].action) {
        .layout => |value| {
            try std.testing.expectEqualStrings("mark", value.name);
            try std.testing.expectEqualStrings("a", value.args[0]);
        },
        else => return error.ExpectedLayoutAction,
    }
}

test "the same chord may have distinct actions in one-shot modes" {
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try vm.evalValue(
        "return {" ++
            "{ key = 'm', modifiers = {'alt'}, action = { name = 'enter-mode', args = {'mark'} } }," ++
            "{ mode = 'mark', key = 'a', action = { name = 'layout', args = {'mark', 'a'} } }," ++
            "{ mode = 'clear-mark', key = 'a', action = { name = 'layout', args = {'clear-mark', 'a'} } }" ++
            "}",
        "=binding-modes-test",
    );
    const bindings = try parse(std.testing.allocator, &vm);
    defer {
        for (bindings) |*binding| binding.deinit(std.testing.allocator);
        std.testing.allocator.free(bindings);
    }
    try std.testing.expectEqual(@as(usize, 3), bindings.len);
    switch (bindings[0].action) {
        .enter_mode => |mode| try std.testing.expectEqualStrings("mark", mode),
        else => return error.ExpectedEnterModeAction,
    }
    try std.testing.expectEqual(bindings[1].keysym, bindings[2].keysym);
    try std.testing.expect(!std.mem.eql(u8, bindings[1].mode, bindings[2].mode));
}

test "pointer buttons bind like keys, and only they start pointer operations" {
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try vm.evalValue(
        "return {{ key = 'pointer:left', modifiers = {'super'}, " ++
            "action = { name = 'pointer-operation', args = {'drag-window'} } }}",
        "=pointer-bindings-test",
    );
    const bindings = try parse(std.testing.allocator, &vm);
    defer {
        for (bindings) |*binding| binding.deinit(std.testing.allocator);
        std.testing.allocator.free(bindings);
    }
    try std.testing.expectEqual(@as(u32, 0x110), bindings[0].button);
    try std.testing.expectEqual(@as(u32, 0), bindings[0].keysym);
    try std.testing.expectEqualStrings("drag-window", bindings[0].action.pointer_operation.name);

    try vm.evalValue(
        "return {{ key = 'd', action = { name = 'pointer-operation', args = {'drag-window'} } }}",
        "=pointer-operation-on-key-test",
    );
    try std.testing.expectError(error.InvalidAction, parse(std.testing.allocator, &vm));
}
