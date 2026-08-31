//! Owned key bindings and the Lua-to-native action vocabulary.

const std = @import("std");
const wm = @import("whirlpool-wm");
const lua_vm = @import("../lua_vm.zig");

pub const MaxBindings: usize = 512;
pub const MaxArguments: usize = 16;

pub const TabStep = enum { previous, next };

pub const Action = union(enum) {
    focus: wm.Direction,
    swap: wm.Direction,
    absorb: wm.Direction,
    eject,
    expel: wm.Direction,
    close_focused,
    toggle_float,
    toggle_fullscreen,
    cycle_width: wm.ColumnWidthStep,
    cycle_container_mode,
    focus_tab: TabStep,
    focus_output: TabStep,
    focus_tag: u8,
    send_to_tag: u8,
    spawn: [][]u8,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .spawn => |args| {
                for (args) |arg| allocator.free(arg);
                allocator.free(args);
            },
            else => {},
        }
        self.* = undefined;
    }
};

pub const Binding = struct {
    key: []u8,
    keysym: u32,
    modifiers: u32,
    action: Action,

    pub fn deinit(self: *Binding, allocator: std.mem.Allocator) void {
        self.action.deinit(allocator);
        allocator.free(self.key);
        self.* = undefined;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidBindings,
    InvalidBinding,
    InvalidAction,
    InvalidModifiers,
    InvalidKey,
    TooManyBindings,
    TooManyArguments,
    DuplicateBinding,
};

pub fn parse(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error![]Binding {
    if (vm.luaType(-1) != .table) return error.InvalidBindings;
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
        vm.setTop(2);
        for (result[0..initialized]) |previous| {
            if (previous.keysym == result[initialized].keysym and
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
    const keysym = keyToKeysym(key) orelse return error.InvalidKey;

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
    const action = try parseAction(allocator, vm);
    vm.setTop(base);
    errdefer action.deinit(allocator);
    return .{ .key = key, .keysym = keysym, .modifiers = modifiers, .action = action };
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
    if (std.mem.eql(u8, name, "focus-tag"))
        return .{ .focus_tag = try parseTagArgument(vm, base, count) };
    if (std.mem.eql(u8, name, "send-to-tag"))
        return .{ .send_to_tag = try parseTagArgument(vm, base, count) };
    if (count != 0) return error.InvalidAction;

    if (directionAction(name, "focus-")) |direction| return .{ .focus = direction };
    if (directionAction(name, "swap-")) |direction| return .{ .swap = direction };
    if (directionAction(name, "absorb-")) |direction| {
        return .{ .absorb = direction };
    }
    if (directionAction(name, "expel-")) |direction| {
        if (direction == .up or direction == .down) return error.InvalidAction;
        return .{ .expel = direction };
    }
    if (std.mem.eql(u8, name, "eject")) return .eject;
    if (std.mem.eql(u8, name, "close-focused")) return .close_focused;
    if (std.mem.eql(u8, name, "toggle-focus-float") or std.mem.eql(u8, name, "toggle-float")) return .toggle_float;
    if (std.mem.eql(u8, name, "toggle-fullscreen")) return .toggle_fullscreen;
    if (std.mem.eql(u8, name, "shrink-width")) return .{ .cycle_width = .previous };
    if (std.mem.eql(u8, name, "grow-width") or std.mem.eql(u8, name, "grow")) return .{ .cycle_width = .next };
    if (std.mem.eql(u8, name, "cycle-container-mode")) return .cycle_container_mode;
    if (std.mem.eql(u8, name, "focus-tab-next")) return .{ .focus_tab = .next };
    if (std.mem.eql(u8, name, "focus-tab-prev")) return .{ .focus_tab = .previous };
    if (std.mem.eql(u8, name, "focus-output-next")) return .{ .focus_output = .next };
    if (std.mem.eql(u8, name, "focus-output-prev")) return .{ .focus_output = .previous };
    return error.InvalidAction;
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

fn parseTagArgument(vm: *lua_vm.Vm, base: c_int, count: usize) Error!u8 {
    if (count != 1) return error.InvalidAction;
    vm.rawGetInteger(-1, 1);
    defer vm.setTop(base + 1);
    const value = vm.integer(-1) orelse return error.InvalidAction;
    if (value < 1 or value > 64) return error.InvalidAction;
    return @intCast(value);
}

fn directionAction(name: []const u8, prefix: []const u8) ?wm.Direction {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const suffix = name[prefix.len..];
    if (std.mem.eql(u8, suffix, "left")) return .left;
    if (std.mem.eql(u8, suffix, "right")) return .right;
    if (std.mem.eql(u8, suffix, "up")) return .up;
    if (std.mem.eql(u8, suffix, "down")) return .down;
    return null;
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

fn keyToKeysym(key: []const u8) ?u32 {
    if (key.len == 1) return key[0];
    const named = std.StaticStringMap(u32).initComptime(.{
        .{ "Return", 0xff0d },            .{ "Tab", 0xff09 },                      .{ "space", 0x20 },
        .{ "comma", ',' },                .{ "period", '.' },                      .{ "slash", '/' },
        .{ "Left", 0xff51 },              .{ "Up", 0xff52 },                       .{ "Right", 0xff53 },
        .{ "Down", 0xff54 },              .{ "XF86AudioRaiseVolume", 0x1008ff13 }, .{ "XF86AudioLowerVolume", 0x1008ff11 },
        .{ "XF86AudioMute", 0x1008ff12 }, .{ "XF86AudioPlay", 0x1008ff14 },        .{ "XF86AudioNext", 0x1008ff17 },
        .{ "XF86AudioPrev", 0x1008ff16 }, .{ "XF86AudioStop", 0x1008ff15 },
    });
    return named.get(key);
}
