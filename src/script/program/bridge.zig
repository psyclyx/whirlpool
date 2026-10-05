//! Lua callback bridge for executing an owned retained program.

const std = @import("std");
const lua_vm = @import("../lua_vm.zig");
const contract = @import("contract.zig");

const Value = contract.Value;
const NodeKind = contract.NodeKind;
const NodeId = contract.NodeId;
const Update = contract.Update;
const Sink = contract.Sink;

const LuaApi = lua_vm.CallbackApi;
const LuaState = lua_vm.State;
const CFunction = lua_vm.CFunction;

const lua_type_none: c_int = -1;
const lua_type_nil: c_int = 0;
const lua_type_boolean: c_int = 1;
const lua_type_number: c_int = 3;
const lua_type_string: c_int = 4;
const lua_type_table: c_int = 5;
const first_upvalue_index: c_int = -1001001;
const next_id_global: [*:0]const u8 = "whirlpool_retained_next_node_id";
const Error = anyerror;

/// Build the VM execution bridge for an owned program representation.
pub fn Execution(comptime Program: type) type {
    return struct {
        const Bridge = @This();

        vm: *lua_vm.Vm,
        program: *const Program,
        sink: *const Sink,
        api: LuaApi,
        next_id: NodeId = 1,
        operations: usize = 0,
        scratch: std.heap.ArenaAllocator,
        update: ?Update = null,

        /// Initialize a callback bridge for one bounded invocation.
        pub fn init(vm: *lua_vm.Vm, program: *const Program, sink: *const Sink) Bridge {
            const bridge: Bridge = .{
                .vm = vm,
                .program = program,
                .sink = sink,
                .api = vm.callbackApi(),
                .scratch = std.heap.ArenaAllocator.init(program.allocator),
            };
            bridge.assertValid();
            return bridge;
        }

        /// Remove native callbacks and release invocation scratch storage.
        pub fn deinit(self: *Bridge) void {
            self.assertValid();
            const state = self.api.state;
            self.api.push_nil(state);
            self.api.set_global(state, "whirlpool_native_create");
            self.api.push_nil(state);
            self.api.set_global(state, "whirlpool_native_set");
            self.api.push_nil(state);
            self.api.set_global(state, "whirlpool_native_require");
            self.api.push_nil(state);
            self.api.set_global(state, "whirlpool_native_update_service");
            self.api.push_nil(state);
            self.api.set_global(state, "whirlpool_native_update_count");
            self.api.push_nil(state);
            self.api.set_global(state, "whirlpool_native_update_value");
            self.api.push_nil(state);
            self.api.set_global(state, "whirlpool_native_bounds");
            self.api.push_nil(state);
            self.api.set_global(state, "whirlpool_native_act");
            self.api.set_top(state, 0);
            self.scratch.deinit();
            self.* = undefined;
        }

        /// Install the retained-program callback vocabulary.
        pub fn install(self: *Bridge) Error!void {
            self.assertValid();
            const state = self.api.state;
            _ = self.api.get_global(state, next_id_global);
            var is_number: c_int = 0;
            const retained_next_id = self.api.to_integer(state, -1, &is_number);
            if (is_number != 0 and retained_next_id > 0 and retained_next_id <= std.math.maxInt(NodeId))
                self.next_id = @intCast(retained_next_id);
            self.api.set_top(state, 0);
            try self.installFunction("whirlpool_native_create", nativeCreateCallback);
            try self.installFunction("whirlpool_native_set", nativeSetCallback);
            try self.installFunction("whirlpool_native_require", nativeRequireCallback);
            try self.installFunction("whirlpool_native_update_service", nativeUpdateServiceCallback);
            try self.installFunction("whirlpool_native_update_count", nativeUpdateCountCallback);
            try self.installFunction("whirlpool_native_update_value", nativeUpdateValueCallback);
            try self.installFunction("whirlpool_native_bounds", nativeBoundsCallback);
            try self.installFunction("whirlpool_native_act", nativeActCallback);
            self.api.set_top(state, 0);
            if (self.api.load_buffer(state, bootstrap_source.ptr, bootstrap_source.len, "=whirlpool.bootstrap", null) != 0)
                return self.callbackFailed("bootstrap load");
            if (self.api.protectedCall(self.vm, 0, 0) != 0) return self.callbackFailed("bootstrap");
            std.debug.assert(self.api.get_top(state) == 0);
        }

        fn installFunction(self: *Bridge, name: [*:0]const u8, function: CFunction) Error!void {
            self.api.push_lightuserdata(self.api.state, @ptrCast(self));
            self.api.push_cclosure(self.api.state, function, 1);
            self.api.set_global(self.api.state, name);
        }

        fn nativeRequire(self: *Bridge) c_int {
            const module_name = self.stringAt(1) catch return self.raise("module name must be a string");
            const requested_name = if (std.mem.eql(u8, module_name, "__whirlpool_entry__"))
                self.program.entry_name
            else
                module_name;
            for (self.program.modules) |module| {
                if (std.mem.eql(u8, module.name, requested_name)) return self.runModule(module.name, module.source);
            }
            // Anything else is an ordinary Lua module, found on `package.path`.
            const state = self.api.state;
            _ = self.api.get_global(state, "require");
            _ = self.api.push_lstring(state, requested_name.ptr, requested_name.len);
            if (self.api.protectedCall(self.vm, 1, 1) != 0) return self.api.lua_error(state);
            return 1;
        }

        fn runModule(self: *Bridge, name: []const u8, source: []const u8) c_int {
            const state = self.api.state;
            const prefix = "local require = whirlpool_require\n";
            const scratch = self.scratch.allocator();
            const wrapped = std.mem.concat(scratch, u8, &.{ prefix, source }) catch
                return self.raise("module source allocation failed");
            const chunk_name = std.fmt.allocPrintSentinel(scratch, "@{s}", .{name}, 0) catch
                return self.raise("module source allocation failed");
            if (self.api.load_buffer(state, wrapped.ptr, wrapped.len, chunk_name.ptr, null) != 0)
                return self.api.lua_error(state);
            if (self.api.protectedCall(self.vm, 0, 1) != 0) return self.api.lua_error(state);
            return 1;
        }

        /// Execute the configured entry module once.
        pub fn runEntry(self: *Bridge) Error!void {
            self.assertValid();
            const state = self.api.state;
            self.api.set_top(state, 0);
            if (self.api.load_buffer(state, entry_source.ptr, entry_source.len, "=whirlpool.entry", null) != 0)
                return self.callbackFailed("entry load");
            if (self.api.protectedCall(self.vm, 0, 0) != 0) return self.callbackFailed("entry");
            self.assertValid();
        }

        /// Deliver the active service update to the retained controller.
        pub fn runUpdate(self: *Bridge) Error!void {
            self.assertValid();
            if (self.update == null) return error.InvalidProperty;
            const state = self.api.state;
            self.api.set_top(state, 0);
            if (self.api.load_buffer(state, update_source.ptr, update_source.len, "=whirlpool.update", null) != 0)
                return self.callbackFailed("update load");
            if (self.api.protectedCall(self.vm, 0, 0) != 0) return self.callbackFailed("update");
            self.assertValid();
        }

        fn callbackFailed(self: *Bridge, phase: []const u8) error{LuaCallbackFailed} {
            var length: usize = 0;
            const message = if (self.api.to_lstring(self.api.state, -1, &length)) |pointer|
                pointer[0..length]
            else
                "unknown Lua error";
            std.log.err("Lua retained-program {s} failed: {s}", .{ phase, message });
            return error.LuaCallbackFailed;
        }

        fn nativeUpdateService(self: *Bridge) c_int {
            const update = self.update orelse return self.raise("no service update is active");
            _ = self.api.push_lstring(self.api.state, update.service.ptr, update.service.len);
            return 1;
        }

        fn nativeUpdateCount(self: *Bridge) c_int {
            const update = self.update orelse return self.raise("no service update is active");
            self.api.push_integer(self.api.state, @intCast(update.values.len));
            return 1;
        }

        fn nativeUpdateValue(self: *Bridge) c_int {
            const update = self.update orelse return self.raise("no service update is active");
            var is_number: c_int = 0;
            const index = self.api.to_integer(self.api.state, 1, &is_number);
            if (is_number == 0 or index < 1 or index > update.values.len) return self.raise("invalid service update index");
            self.pushValue(update.values[@intCast(index - 1)]) catch |err| return self.raise(@errorName(err));
            return 1;
        }

        fn pushValue(self: *Bridge, value: Value) Error!void {
            const state = self.api.state;
            switch (value) {
                .nil => self.api.push_nil(state),
                .boolean => |item| self.api.push_boolean(state, @intFromBool(item)),
                .number => |item| {
                    if (!std.math.isFinite(item)) return error.InvalidProperty;
                    self.api.push_number(state, item);
                },
                .string => |item| {
                    if (item.len > self.program.limits.max_property_bytes) return error.PropertyTooLarge;
                    _ = self.api.push_lstring(state, item.ptr, item.len);
                },
                .array => |items| {
                    if (items.len > self.program.limits.max_update_items) return error.PropertyItemLimitExceeded;
                    self.api.create_table(state, @intCast(items.len), 0);
                    for (items, 0..) |item, index| {
                        try self.pushValue(item);
                        self.api.raw_set_i(state, -2, @intCast(index + 1));
                    }
                },
                .object => |fields| {
                    if (fields.len > self.program.limits.max_update_items) return error.PropertyItemLimitExceeded;
                    self.api.create_table(state, 0, @intCast(fields.len));
                    for (fields) |field| {
                        _ = self.api.push_lstring(state, field.key.ptr, field.key.len);
                        try self.pushValue(field.value);
                        self.api.raw_set(state, -3);
                    }
                },
            }
        }

        fn nativeCreate(self: *Bridge) c_int {
            const state = self.api.state;
            const kind = self.stringAt(1) catch return self.raise("retained create kind must be a string");
            const kind_value = parseNodeKind(kind) orelse return self.raise("unknown retained node kind");
            var parent: ?NodeId = null;
            if (self.api.type_of(state, 2) != lua_type_nil) {
                var is_number: c_int = 0;
                const raw = self.api.to_integer(state, 2, &is_number);
                if (is_number == 0 or raw < 0 or raw > std.math.maxInt(NodeId)) return self.raise("invalid retained parent");
                parent = @intCast(raw);
            }
            const id = self.next_id;
            if (id == std.math.maxInt(NodeId)) return self.raise("retained node id space exhausted");
            self.next_id +|= 1;
            self.api.push_integer(state, self.next_id);
            self.api.set_global(state, next_id_global);
            self.countOperation() catch |err| return self.raise(@errorName(err));
            self.sink.create(self.sink.context, id, kind_value, parent) catch |err| return self.raise(@errorName(err));
            self.api.push_integer(state, id);
            return 1;
        }

        fn nativeSet(self: *Bridge) c_int {
            const state = self.api.state;
            var is_number: c_int = 0;
            const raw_id = self.api.to_integer(state, 1, &is_number);
            if (is_number == 0 or raw_id <= 0 or raw_id > std.math.maxInt(NodeId)) return self.raise("invalid retained node");
            const key = self.stringAt(2) catch return self.raise("retained property name must be a string");
            const value = self.valueAt(3, 0) catch |err| return self.raise(@errorName(err));
            self.countOperation() catch |err| return self.raise(@errorName(err));
            self.sink.set(self.sink.context, @intCast(raw_id), key, value) catch |err| return self.raise(@errorName(err));
            return 0;
        }

        fn nativeAct(self: *Bridge) c_int {
            const state = self.api.state;
            const name = self.stringAt(1) catch return self.raise("action name must be a string");
            const count: usize = @intCast(@max(0, self.api.get_top(state) - 1));
            if (count > 8) return self.raise("too many action arguments");
            var args: [8][]const u8 = undefined;
            for (0..count) |index| {
                args[index] = self.stringAt(@intCast(index + 2)) catch return self.raise("action arguments must be strings");
            }
            const handler = self.sink.act orelse return 0;
            handler(self.sink.context, name, args[0..count]) catch |err| return self.raise(@errorName(err));
            return 0;
        }

        fn nativeBounds(self: *Bridge) c_int {
            const state = self.api.state;
            var is_number: c_int = 0;
            const raw_id = self.api.to_integer(state, 1, &is_number);
            if (is_number == 0 or raw_id <= 0 or raw_id > std.math.maxInt(NodeId)) return self.raise("invalid retained node");
            const query = self.sink.bounds orelse {
                self.api.push_nil(state);
                return 1;
            };
            const box = query(self.sink.context, @intCast(raw_id)) catch |err| return self.raise(@errorName(err));
            const value = box orelse {
                self.api.push_nil(state);
                return 1;
            };
            self.api.create_table(state, 0, 4);
            inline for (.{ "x", "y", "width", "height" }, 0..) |name, index| {
                self.api.push_number(state, value[index]);
                self.api.set_field(state, -2, name);
            }
            return 1;
        }

        fn nativePreload(self: *Bridge) c_int {
            const module_name = self.stringAt(1) catch return self.raise("module name must be a string");
            const requested_name = if (std.mem.eql(u8, module_name, "__whirlpool_entry__"))
                self.program.entry_name
            else
                module_name;
            for (self.program.modules) |module| {
                if (!std.mem.eql(u8, module.name, requested_name)) continue;
                if (self.api.load_buffer(self.api.state, module.source.ptr, module.source.len, module.name.ptr, null) != 0)
                    return 1;
                return 1;
            }
            return self.raise("module not found");
        }

        fn valueAt(self: *Bridge, index: c_int, depth: usize) Error!Value {
            if (depth > self.program.limits.max_property_depth) return error.PropertyDepthExceeded;
            const state = self.api.state;
            return switch (self.api.type_of(state, index)) {
                lua_type_nil, lua_type_none => .nil,
                lua_type_boolean => .{ .boolean = self.api.to_boolean(state, index) != 0 },
                lua_type_number => blk: {
                    var is_number: c_int = 0;
                    const number = self.api.to_number(state, index, &is_number);
                    if (is_number == 0 or !std.math.isFinite(number)) return error.InvalidProperty;
                    break :blk .{ .number = number };
                },
                lua_type_string => .{ .string = try self.stringAt(index) },
                // A sequence is an array; a table of named fields (and no
                // sequence) an object; an empty table an empty array.
                lua_type_table => if (self.api.raw_len(state, index) == 0)
                    try self.objectAt(index, depth + 1)
                else
                    try self.arrayAt(index, depth + 1),
                else => error.InvalidProperty,
            };
        }

        fn arrayAt(self: *Bridge, index: c_int, depth: usize) Error!Value {
            const state = self.api.state;
            var items = std.ArrayList(Value).empty;
            errdefer items.deinit(self.scratch.allocator());
            var item_index: i64 = 1;
            while (item_index <= @as(i64, @intCast(self.program.limits.max_property_items))) {
                const before = self.api.get_top(state);
                _ = self.api.raw_get_i(state, index, item_index);
                if (self.api.type_of(state, -1) == lua_type_nil) {
                    self.api.set_top(state, before);
                    break;
                }
                try items.append(self.scratch.allocator(), try self.valueAt(-1, depth));
                self.api.set_top(state, before);
                item_index += 1;
            }
            if (item_index > @as(i64, @intCast(self.program.limits.max_property_items))) return error.PropertyItemLimitExceeded;
            const copied = try self.scratch.allocator().dupe(Value, items.items);
            return .{ .array = copied };
        }

        /// A table's string-keyed fields, in Lua's iteration order; an empty
        /// array when it has none. Keys of any other type are an error.
        fn objectAt(self: *Bridge, index: c_int, depth: usize) Error!Value {
            const state = self.api.state;
            // `lua_next` pushes as it goes, so the table needs a fixed index.
            const table = if (index < 0) self.api.get_top(state) + index + 1 else index;
            var fields = std.ArrayList(Value.Field).empty;
            errdefer fields.deinit(self.scratch.allocator());
            self.api.push_nil(state);
            while (self.api.next(state, table) != 0) {
                // Checked before reading: converting a number key in place
                // would derail the iteration.
                if (self.api.type_of(state, -2) != lua_type_string) return error.InvalidProperty;
                if (fields.items.len == self.program.limits.max_property_items) return error.PropertyItemLimitExceeded;
                const key = try self.stringAt(-2);
                try fields.append(self.scratch.allocator(), .{ .key = key, .value = try self.valueAt(-1, depth) });
                // Pop the value, keeping the key for the next step.
                self.api.set_top(state, self.api.get_top(state) - 1);
            }
            if (fields.items.len == 0) return .{ .array = &.{} };
            return .{ .object = try self.scratch.allocator().dupe(Value.Field, fields.items) };
        }

        fn stringAt(self: *Bridge, index: c_int) Error![]const u8 {
            var length: usize = 0;
            const pointer = self.api.to_lstring(self.api.state, index, &length) orelse return error.LuaTypeError;
            if (length > self.program.limits.max_property_bytes) return error.PropertyTooLarge;
            return pointer[0..length];
        }

        fn raise(self: *Bridge, message: []const u8) c_int {
            const state = self.api.state;
            _ = self.api.push_lstring(state, message.ptr, message.len);
            return self.api.lua_error(state);
        }

        fn countOperation(self: *Bridge) Error!void {
            if (self.operations >= self.program.limits.max_operations)
                return error.OperationLimitExceeded;
            self.operations += 1;
            std.debug.assert(self.operations <= self.program.limits.max_operations);
        }

        fn assertValid(self: *const Bridge) void {
            std.debug.assert(self.next_id != 0);
            std.debug.assert(self.operations <= self.program.limits.max_operations);
            std.debug.assert(self.program.limits.max_operations > 0);
        }

        fn bridgeFromState(state: *LuaState) ?*Bridge {
            const raw = lua_vm.callbackContext(state, first_upvalue_index) orelse return null;
            return @ptrCast(@alignCast(raw));
        }

        fn nativeCreateCallback(state: *LuaState) callconv(.c) c_int {
            return (bridgeFromState(state) orelse return 0).nativeCreate();
        }

        fn nativeSetCallback(state: *LuaState) callconv(.c) c_int {
            return (bridgeFromState(state) orelse return 0).nativeSet();
        }

        fn nativeRequireCallback(state: *LuaState) callconv(.c) c_int {
            return (bridgeFromState(state) orelse return 0).nativeRequire();
        }

        fn nativeUpdateServiceCallback(state: *LuaState) callconv(.c) c_int {
            return (bridgeFromState(state) orelse return 0).nativeUpdateService();
        }

        fn nativeUpdateCountCallback(state: *LuaState) callconv(.c) c_int {
            return (bridgeFromState(state) orelse return 0).nativeUpdateCount();
        }

        fn nativeUpdateValueCallback(state: *LuaState) callconv(.c) c_int {
            return (bridgeFromState(state) orelse return 0).nativeUpdateValue();
        }

        fn nativeBoundsCallback(state: *LuaState) callconv(.c) c_int {
            return (bridgeFromState(state) orelse return 0).nativeBounds();
        }

        fn nativeActCallback(state: *LuaState) callconv(.c) c_int {
            return (bridgeFromState(state) orelse return 0).nativeAct();
        }
    };
}

fn parseNodeKind(name: []const u8) ?NodeKind {
    inline for (@typeInfo(NodeKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

const entry_source = "local main = whirlpool_native_require(\"__whirlpool_entry__\")\nlocal root = whirlpool_native_root()\nwhirlpool_program_controller = main(root)";

const update_source =
    "local controller = whirlpool_program_controller\n" ++
    "if controller and controller.update then\n" ++
    "  local values = {}\n" ++
    "  for index = 1, whirlpool_native_update_count() do values[index] = whirlpool_native_update_value(index) end\n" ++
    "  controller:update(whirlpool_native_update_service(), values)\n" ++
    "end\n";

const bootstrap_source =
    "whirlpool_loaded_modules = whirlpool_loaded_modules or {}\n" ++
    "function whirlpool_require(name)\n" ++
    "  local value = whirlpool_loaded_modules[name]\n" ++
    "  if value == nil then\n" ++
    "    value = whirlpool_native_require(name)\n" ++
    "    if value == nil then value = true end\n" ++
    "    whirlpool_loaded_modules[name] = value\n" ++
    "  end\n" ++
    "  return value\n" ++
    "end\n" ++
    "local function emit(kind, parent, properties)\n" ++
    "  local id = whirlpool_native_create(kind, parent)\n" ++
    "  local node = { __id = id }\n" ++
    "  function node:set(key, value) whirlpool_native_set(self.__id, key, value); return self end\n" ++
    "  function node:set_property(key, value) return self:set(key, value) end\n" ++
    "  function node:bounds() return whirlpool_native_bounds(self.__id) end\n" ++
    "  local function child(child_kind, child_properties) return emit(child_kind, node.__id, child_properties) end\n" ++
    "  function node:row(p) return child('row', p) end\n" ++
    "  function node:column(p) return child('column', p) end\n" ++
    "  function node:stack(p) return child('stack', p) end\n" ++
    "  function node:spacer(p) return child('spacer', p) end\n" ++
    "  function node:shape(p) return child('shape', p) end\n" ++
    "  function node:polygon(p) return child('polygon', p) end\n" ++
    "  function node:text(p) return child('text', p) end\n" ++
    "  function node:icon(p) return child('icon', p) end\n" ++
    "  if properties then for key, value in pairs(properties) do whirlpool_native_set(id, key, value) end end\n" ++
    "  return node\n" ++
    "end\n" ++
    "function whirlpool_native_root() return emit('stack', nil, nil) end\n";
