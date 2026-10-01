//! Bounded Lua program loading and retained-node operation emission.
//!
//! This is the public seam between the Lua package world and a host that owns
//! a retained scene. It deliberately knows neither UI node handles nor any
//! compositor/graphics object. Lua modules return ordinary functions; the
//! host installs a small retained vocabulary and receives typed operations.

const std = @import("std");
const lua_vm = @import("../lua_vm.zig");
const lua_bridge = @import("bridge.zig");
const contract = @import("contract.zig");

const Allocator = std.mem.Allocator;

pub const Vm = lua_vm.Vm;

pub const Limits = contract.Limits;
pub const Module = contract.Module;
pub const Value = contract.Value;
pub const NodeKind = contract.NodeKind;
pub const NodeId = contract.NodeId;
pub const Update = contract.Update;
pub const Sink = contract.Sink;

/// Arena-owned service update for work that outlives the Lua/host callback
/// which produced its borrowed strings and arrays.
pub const OwnedUpdate = struct {
    arena: std.heap.ArenaAllocator,
    value: Update,

    pub fn clone(backing: Allocator, source: Update) !OwnedUpdate {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const service = try allocator.dupe(u8, source.service);
        const values = try allocator.alloc(Value, source.values.len);
        for (source.values, values) |item, *destination|
            destination.* = try cloneValue(allocator, item);
        return .{ .arena = arena, .value = .{ .service = service, .values = values } };
    }

    pub fn deinit(self: *OwnedUpdate) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn eql(self: *const OwnedUpdate, source: Update) bool {
        if (!std.mem.eql(u8, self.value.service, source.service)) return false;
        if (self.value.values.len != source.values.len) return false;
        for (self.value.values, source.values) |left, right|
            if (!eqlValue(left, right)) return false;
        return true;
    }

    fn cloneValue(allocator: Allocator, source: Value) !Value {
        return switch (source) {
            .nil => .nil,
            .boolean => |value| .{ .boolean = value },
            .number => |value| .{ .number = value },
            .string => |value| .{ .string = try allocator.dupe(u8, value) },
            .array => |value| blk: {
                const items = try allocator.alloc(Value, value.len);
                for (value, items) |item, *destination|
                    destination.* = try cloneValue(allocator, item);
                break :blk .{ .array = items };
            },
            .object => |value| blk: {
                const fields = try allocator.alloc(Value.Field, value.len);
                for (value, fields) |field, *destination| destination.* = .{
                    .key = try allocator.dupe(u8, field.key),
                    .value = try cloneValue(allocator, field.value),
                };
                break :blk .{ .object = fields };
            },
        };
    }

    fn eqlValue(left: Value, right: Value) bool {
        return switch (left) {
            .nil => right == .nil,
            .boolean => |value| switch (right) {
                .boolean => |other| value == other,
                else => false,
            },
            .number => |value| switch (right) {
                .number => |other| value == other,
                else => false,
            },
            .string => |value| switch (right) {
                .string => |other| std.mem.eql(u8, value, other),
                else => false,
            },
            .array => |value| switch (right) {
                .array => |other| blk: {
                    if (value.len != other.len) break :blk false;
                    for (value, other) |item, other_item|
                        if (!eqlValue(item, other_item)) break :blk false;
                    break :blk true;
                },
                else => false,
            },
            .object => |value| switch (right) {
                .object => |other| blk: {
                    if (value.len != other.len) break :blk false;
                    for (value, other) |field, other_field| {
                        if (!std.mem.eql(u8, field.key, other_field.key)) break :blk false;
                        if (!eqlValue(field.value, other_field.value)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
        };
    }
};

pub const Error = Allocator.Error || lua_vm.Error || error{
    InvalidEntry,
    DuplicateModule,
    InvalidModuleName,
    ModuleNotFound,
    ModuleLimitExceeded,
    ModuleTooLarge,
    OperationLimitExceeded,
    PropertyTooLarge,
    PropertyDepthExceeded,
    PropertyItemLimitExceeded,
    InvalidProperty,
    MissingSymbol,
    LuaStackCorrupt,
    LuaTypeError,
    LuaCallbackFailed,
};

test "owned updates recursively detach and compare borrowed values" {
    const nested = [_]Value{.{ .string = "title" }};
    const source = [_]Value{.{ .array = &nested }};
    var owned = try OwnedUpdate.clone(std.testing.allocator, .{ .service = "desktop", .values = &source });
    defer owned.deinit();
    try std.testing.expectEqualStrings("desktop", owned.value.service);
    try std.testing.expectEqualStrings("title", owned.value.values[0].array[0].string);
    try std.testing.expect(owned.eql(.{ .service = "desktop", .values = &source }));

    const changed_nested = [_]Value{.{ .string = "other" }};
    const changed = [_]Value{.{ .array = &changed_nested }};
    try std.testing.expect(!owned.eql(.{ .service = "desktop", .values = &changed }));
}

pub const Program = struct {
    allocator: Allocator,
    limits: Limits,
    entry_name: []u8,
    modules: []OwnedModule,
    /// Modules found after `modules`, borrowed: many programs (a decoration per
    /// window) share one configuration's sources, which outlive them.
    shared: []const Module = &.{},

    const OwnedModule = struct {
        name: [:0]u8,
        source: []u8,

        fn deinit(self: *OwnedModule, allocator: Allocator) void {
            std.debug.assert(self.name.len > 0);
            allocator.free(self.source);
            allocator.free(self.name);
            self.* = undefined;
        }
    };

    /// Release every owned module and the selected entry name.
    pub fn deinit(self: *Program) void {
        self.assertValid();
        for (self.modules) |*module| module.deinit(self.allocator);
        self.allocator.free(self.modules);
        self.allocator.free(self.entry_name);
        self.* = undefined;
    }

    /// Return the explicitly selected entry module name.
    pub fn entryName(self: *const Program) []const u8 {
        self.assertValid();
        return self.entry_name;
    }

    /// Return the number of owned source modules.
    pub fn moduleCount(self: *const Program) usize {
        self.assertValid();
        return self.modules.len;
    }

    /// Execute the entry module against a host sink. All Lua callbacks and
    /// borrowed property slices end before this function returns.
    pub fn instantiate(self: *const Program, vm: *lua_vm.Vm, sink: *const Sink) anyerror!void {
        self.assertValid();
        var execution = lua_bridge.Execution(Program).init(vm, self, sink);
        defer execution.deinit();
        try execution.install();
        try sink.begin(sink.context);
        errdefer sink.finish(sink.context) catch {};
        try execution.runEntry();
        try sink.finish(sink.context);
    }

    /// Deliver one named service update to the controller returned by the entry
    /// module. Values are borrowed for this bounded callback only.
    pub fn update(self: *const Program, vm: *lua_vm.Vm, sink: *const Sink, value: Update) anyerror!void {
        self.assertValid();
        var execution = lua_bridge.Execution(Program).init(vm, self, sink);
        execution.update = value;
        defer execution.deinit();
        try execution.install();
        try sink.begin(sink.context);
        errdefer sink.finish(sink.context) catch {};
        try execution.runUpdate();
        try sink.finish(sink.context);
    }

    fn assertValid(self: *const Program) void {
        std.debug.assert(self.entry_name.len > 0);
        std.debug.assert(self.modules.len > 0);
        std.debug.assert(self.modules.len <= self.limits.max_modules);
        var found_entry = false;
        for (self.modules, 0..) |module, index| {
            std.debug.assert(module.name.len > 0);
            std.debug.assert(module.source.len <= self.limits.max_module_bytes);
            if (std.mem.eql(u8, module.name, self.entry_name)) found_entry = true;
            for (self.modules[index + 1 ..]) |other|
                std.debug.assert(!std.mem.eql(u8, module.name, other.name));
        }
        std.debug.assert(found_entry);
    }
};

pub const Loader = struct {
    allocator: Allocator,
    limits: Limits = .{},

    /// Initialize a loader with explicit resource limits.
    pub fn init(allocator: Allocator, limits: Limits) Loader {
        std.debug.assert(limits.max_modules > 0);
        std.debug.assert(limits.max_module_name_bytes > 0);
        std.debug.assert(limits.max_operations > 0);
        return .{ .allocator = allocator, .limits = limits };
    }

    /// Validate and own an explicitly selected entry module and its dependency
    /// sources. Program metadata is supplied by the host, never executed as
    /// Lua or self-declared by the loaded program.
    pub fn load(
        self: Loader,
        entry_name: []const u8,
        modules: []const Module,
    ) Error!Program {
        if (entry_name.len == 0 or entry_name.len > self.limits.max_module_name_bytes or
            !validModuleName(entry_name)) return error.InvalidEntry;

        if (modules.len == 0 or modules.len > self.limits.max_modules) return error.ModuleLimitExceeded;
        const owned_entry = try self.allocator.dupe(u8, entry_name);
        errdefer self.allocator.free(owned_entry);
        const owned = try self.allocator.alloc(Program.OwnedModule, modules.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |*module| module.deinit(self.allocator);
            self.allocator.free(owned);
        }
        for (modules, 0..) |module, index| {
            if (module.name.len == 0 or module.name.len > self.limits.max_module_name_bytes or
                !validModuleName(module.name)) return error.InvalidModuleName;
            if (module.source.len > self.limits.max_module_bytes) return error.ModuleTooLarge;
            for (modules[0..index]) |previous| {
                if (std.mem.eql(u8, previous.name, module.name)) return error.DuplicateModule;
            }
            owned[index] = .{
                .name = try self.allocator.dupeZ(u8, module.name),
                .source = try self.allocator.dupe(u8, module.source),
            };
            initialized += 1;
        }

        var entry_found = false;
        for (owned) |module| {
            if (std.mem.eql(u8, module.name, entry_name)) entry_found = true;
        }
        if (!entry_found) return error.ModuleNotFound;

        const program = Program{
            .allocator = self.allocator,
            .limits = self.limits,
            .entry_name = owned_entry,
            .modules = owned,
        };
        program.assertValid();
        std.debug.assert(std.mem.eql(u8, program.entryName(), entry_name));
        return program;
    }

    /// Like `load`, with `shared` modules available to `require` as well. They
    /// are borrowed and must outlive the program.
    pub fn loadShared(
        self: Loader,
        entry_name: []const u8,
        modules: []const Module,
        shared: []const Module,
    ) Error!Program {
        var program = try self.load(entry_name, modules);
        program.shared = shared;
        return program;
    }
};

fn validModuleName(name: []const u8) bool {
    if (name.len == 0) return false;
    var segment_start = true;
    for (name) |character| {
        if (character == '.') {
            if (segment_start) return false;
            segment_start = true;
            continue;
        }
        if ((character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9' and !segment_start) or character == '_')
        {
            segment_start = false;
            continue;
        }
        return false;
    }
    return !segment_start;
}

test "module names are bounded and unambiguous" {
    try std.testing.expect(validModuleName("whirlpool.widgets.bar"));
    try std.testing.expect(!validModuleName("../bar"));
    try std.testing.expect(!validModuleName(".bar"));
}
