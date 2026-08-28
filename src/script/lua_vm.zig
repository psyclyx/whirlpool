const std = @import("std");

/// Opaque PUC Lua state. The declarations below intentionally cover only the
/// protected loading/call surface owned by this module; no Lua userdata can
/// contain a compositor, graphics, or WM pointer.
pub const State = opaque {};

const NewState = *const fn () callconv(.c) ?*State;
const OpenLibs = *const fn (*State) callconv(.c) void;
const Close = *const fn (*State) callconv(.c) void;
const LoadBuffer = *const fn (*State, [*]const u8, usize, [*:0]const u8, ?[*:0]const u8) callconv(.c) c_int;
const PCall = *const fn (*State, c_int, c_int, c_int, isize, ?*const anyopaque) callconv(.c) c_int;
const GetTop = *const fn (*State) callconv(.c) c_int;
const SetTop = *const fn (*State, c_int) callconv(.c) void;
const TypeOf = *const fn (*State, c_int) callconv(.c) c_int;
const GetField = *const fn (*State, c_int, [*:0]const u8) callconv(.c) c_int;
const SetField = *const fn (*State, c_int, [*:0]const u8) callconv(.c) void;
const GetGlobal = *const fn (*State, [*:0]const u8) callconv(.c) c_int;
const SetGlobal = *const fn (*State, [*:0]const u8) callconv(.c) void;
const RawGetI = *const fn (*State, c_int, i64) callconv(.c) c_int;
const RawSetI = *const fn (*State, c_int, i64) callconv(.c) void;
const RawLen = *const fn (*State, c_int) callconv(.c) usize;
const ToInteger = *const fn (*State, c_int, ?*c_int) callconv(.c) i64;
const ToNumber = *const fn (*State, c_int, ?*c_int) callconv(.c) f64;
const ToBoolean = *const fn (*State, c_int) callconv(.c) c_int;
const ToLString = *const fn (*State, c_int, *usize) callconv(.c) ?[*]const u8;
const PushNil = *const fn (*State) callconv(.c) void;
const PushInteger = *const fn (*State, i64) callconv(.c) void;
const PushNumber = *const fn (*State, f64) callconv(.c) void;
const PushBoolean = *const fn (*State, c_int) callconv(.c) void;
const PushLStringValue = *const fn (*State, [*]const u8, usize) callconv(.c) [*]const u8;
const PushLightUserdata = *const fn (*State, ?*anyopaque) callconv(.c) void;
pub const CFunction = *const fn (*State) callconv(.c) c_int;
const PushCClosure = *const fn (*State, CFunction, c_int) callconv(.c) void;
const CreateTable = *const fn (*State, c_int, c_int) callconv(.c) void;
const Hook = *const fn (*State, *anyopaque) callconv(.c) void;
const SetHook = *const fn (*State, ?Hook, c_int, c_int) callconv(.c) void;
const PushLString = *const fn (*State, [*]const u8, usize) callconv(.c) [*:0]const u8;
const LuaError = *const fn (*State) callconv(.c) c_int;
const ToUserdata = *const fn (*State, c_int) callconv(.c) ?*anyopaque;
pub const InstructionHook = *const fn (?*anyopaque, u64) callconv(.c) bool;

const Api = struct {
    library: std.DynLib,
    new_state: NewState,
    open_libs: OpenLibs,
    close: Close,
    load_buffer: LoadBuffer,
    pcall: PCall,
    get_top: GetTop,
    set_top: SetTop,
    type_of: TypeOf,
    get_field: GetField,
    set_field: SetField,
    get_global: GetGlobal,
    set_global: SetGlobal,
    raw_get_i: RawGetI,
    raw_set_i: RawSetI,
    raw_len: RawLen,
    to_integer: ToInteger,
    to_number: ToNumber,
    to_boolean: ToBoolean,
    to_lstring: ToLString,
    push_nil: PushNil,
    push_integer: PushInteger,
    push_number: PushNumber,
    push_boolean: PushBoolean,
    push_lstring_value: PushLStringValue,
    push_lightuserdata: PushLightUserdata,
    push_cclosure: PushCClosure,
    create_table: CreateTable,
    set_hook: SetHook,
    push_lstring: PushLString,
    lua_error: LuaError,
    to_userdata: ToUserdata,

    fn open() Error!Api {
        const candidates = [_][]const u8{
            "liblua.so.5.4",
            "liblua5.4.so.0",
            "liblua.so",
            "liblua.so.5.2",
            "/run/current-system/sw/lib/liblua.so",
            "/run/current-system/sw/lib/liblua.so.5.2",
        };
        var library: ?std.DynLib = null;
        for (candidates) |candidate| {
            library = std.DynLib.open(candidate) catch continue;
            break;
        }
        var loaded = library orelse return error.LibraryUnavailable;
        errdefer loaded.close();
        const to_userdata = try symbol(ToUserdata, &loaded, "lua_touserdata");
        return .{
            .library = loaded,
            .new_state = try symbol(NewState, &loaded, "luaL_newstate"),
            .open_libs = try symbol(OpenLibs, &loaded, "luaL_openlibs"),
            .close = try symbol(Close, &loaded, "lua_close"),
            .load_buffer = try symbol(LoadBuffer, &loaded, "luaL_loadbufferx"),
            .pcall = try symbol(PCall, &loaded, "lua_pcallk"),
            .get_top = try symbol(GetTop, &loaded, "lua_gettop"),
            .set_top = try symbol(SetTop, &loaded, "lua_settop"),
            .type_of = try symbol(TypeOf, &loaded, "lua_type"),
            .get_field = try symbol(GetField, &loaded, "lua_getfield"),
            .set_field = try symbol(SetField, &loaded, "lua_setfield"),
            .get_global = try symbol(GetGlobal, &loaded, "lua_getglobal"),
            .set_global = try symbol(SetGlobal, &loaded, "lua_setglobal"),
            .raw_get_i = try symbol(RawGetI, &loaded, "lua_rawgeti"),
            .raw_set_i = try symbol(RawSetI, &loaded, "lua_rawseti"),
            .raw_len = try symbol(RawLen, &loaded, "lua_rawlen"),
            .to_integer = try symbol(ToInteger, &loaded, "lua_tointegerx"),
            .to_number = try symbol(ToNumber, &loaded, "lua_tonumberx"),
            .to_boolean = try symbol(ToBoolean, &loaded, "lua_toboolean"),
            .to_lstring = try symbol(ToLString, &loaded, "lua_tolstring"),
            .push_nil = try symbol(PushNil, &loaded, "lua_pushnil"),
            .push_integer = try symbol(PushInteger, &loaded, "lua_pushinteger"),
            .push_number = try symbol(PushNumber, &loaded, "lua_pushnumber"),
            .push_boolean = try symbol(PushBoolean, &loaded, "lua_pushboolean"),
            .push_lstring_value = try symbol(PushLStringValue, &loaded, "lua_pushlstring"),
            .push_lightuserdata = try symbol(PushLightUserdata, &loaded, "lua_pushlightuserdata"),
            .push_cclosure = try symbol(PushCClosure, &loaded, "lua_pushcclosure"),
            .create_table = try symbol(CreateTable, &loaded, "lua_createtable"),
            .set_hook = try symbol(SetHook, &loaded, "lua_sethook"),
            .push_lstring = try symbol(PushLString, &loaded, "lua_pushlstring"),
            .lua_error = try symbol(LuaError, &loaded, "lua_error"),
            .to_userdata = to_userdata,
        };
    }

    fn deinit(self: *Api) void {
        self.library.close();
        self.* = undefined;
    }
};

/// Raw operations needed to install C closures. This is a borrowed view of a
/// VM's already-loaded ABI, not a second dynamic loader.
pub const CallbackApi = struct {
    state: *State,
    get_top: GetTop,
    set_top: SetTop,
    type_of: TypeOf,
    get_field: GetField,
    set_field: SetField,
    get_global: GetGlobal,
    set_global: SetGlobal,
    push_nil: PushNil,
    push_integer: PushInteger,
    push_number: PushNumber,
    push_boolean: PushBoolean,
    push_lstring: PushLStringValue,
    push_lightuserdata: PushLightUserdata,
    push_cclosure: PushCClosure,
    create_table: CreateTable,
    raw_get_i: RawGetI,
    raw_set_i: RawSetI,
    to_integer: ToInteger,
    to_number: ToNumber,
    to_boolean: ToBoolean,
    to_lstring: ToLString,
    to_userdata: ToUserdata,
    load_buffer: LoadBuffer,
    raw_pcall: PCall,
    lua_error: LuaError,

    /// Call Lua with callback and instruction-hook dispatch scoped to this VM.
    pub fn protectedCall(self: CallbackApi, owner: *Vm, arguments: c_int, results: c_int) c_int {
        const previous_callback = active_callback;
        const previous_vm = active_vm;
        active_callback = .{ .state = self.state, .to_userdata = self.to_userdata };
        active_vm = owner;
        defer {
            active_callback = previous_callback;
            active_vm = previous_vm;
        }
        return self.raw_pcall(self.state, arguments, results, 0, 0, null);
    }
};

fn symbol(comptime T: type, library: *std.DynLib, name: [:0]const u8) Error!T {
    return library.lookup(T, name) orelse error.MissingSymbol;
}

pub const Error = error{
    OutOfMemory,
    LibraryUnavailable,
    MissingSymbol,
    LoadFailed,
    CallFailed,
    InvalidResult,
    InvalidInstructionGranularity,
};

const CallbackBinding = struct {
    state: *State,
    to_userdata: ToUserdata,
};

threadlocal var active_callback: ?CallbackBinding = null;

/// Recover a light-userdata closure upvalue from the VM currently executing
/// this callback. The dynamic-library function pointer never outlives its VM.
pub fn callbackContext(state: *State, index: c_int) ?*anyopaque {
    const binding = active_callback orelse return null;
    if (binding.state != state) return null;
    return binding.to_userdata(state, index);
}

pub const Vm = struct {
    api: Api,
    state: *State,
    instruction_hook: ?InstructionHook = null,
    instruction_context: ?*anyopaque = null,
    instruction_granularity: u64 = 100,

    pub fn init(open_standard_libraries: bool) Error!Vm {
        var api = try Api.open();
        errdefer api.deinit();
        const state = api.new_state() orelse return error.OutOfMemory;
        if (open_standard_libraries) api.open_libs(state);
        return .{ .api = api, .state = state };
    }

    pub fn deinit(self: *Vm) void {
        self.clearInstructionHook();
        self.api.close(self.state);
        self.api.deinit();
        self.* = undefined;
    }

    pub fn stateHandle(self: *Vm) *State {
        return self.state;
    }

    pub fn callbackApi(self: *Vm) CallbackApi {
        return .{
            .state = self.state,
            .get_top = self.api.get_top,
            .set_top = self.api.set_top,
            .type_of = self.api.type_of,
            .get_field = self.api.get_field,
            .set_field = self.api.set_field,
            .get_global = self.api.get_global,
            .set_global = self.api.set_global,
            .push_nil = self.api.push_nil,
            .push_integer = self.api.push_integer,
            .push_number = self.api.push_number,
            .push_boolean = self.api.push_boolean,
            .push_lstring = self.api.push_lstring_value,
            .push_lightuserdata = self.api.push_lightuserdata,
            .push_cclosure = self.api.push_cclosure,
            .create_table = self.api.create_table,
            .raw_get_i = self.api.raw_get_i,
            .raw_set_i = self.api.raw_set_i,
            .to_integer = self.api.to_integer,
            .to_number = self.api.to_number,
            .to_boolean = self.api.to_boolean,
            .to_lstring = self.api.to_lstring,
            .to_userdata = self.api.to_userdata,
            .load_buffer = self.api.load_buffer,
            .raw_pcall = self.api.pcall,
            .lua_error = self.api.lua_error,
        };
    }

    pub fn setInstructionHook(self: *Vm, hook: InstructionHook, context: ?*anyopaque, granularity: u64) Error!void {
        if (granularity == 0 or granularity > std.math.maxInt(c_int)) return error.InvalidInstructionGranularity;
        self.instruction_hook = hook;
        self.instruction_context = context;
        self.instruction_granularity = granularity;
        self.api.set_hook(self.state, instructionHook, 8, @intCast(granularity));
    }

    pub fn clearInstructionHook(self: *Vm) void {
        if (self.instruction_hook != null) self.api.set_hook(self.state, null, 0, 0);
        self.instruction_hook = null;
        self.instruction_context = null;
    }

    /// Run one bounded, non-yielding chunk. Callers must invoke this only from
    /// a Script.Callback safe point; the VM itself never enters River code.
    pub fn run(self: *Vm, source: []const u8, chunk_name: [:0]const u8) Error!void {
        if (self.api.load_buffer(self.state, source.ptr, source.len, chunk_name.ptr, null) != 0) {
            self.discardStack();
            return error.LoadFailed;
        }
        if (self.protectedCall(0, 0) != 0) {
            self.discardStack();
            return error.CallFailed;
        }
    }

    /// Test/support surface for a scalar return. Production bindings will use
    /// typed snapshot and intent userdata instead of exposing arbitrary stack
    /// access to callers.
    pub fn evalInteger(self: *Vm, source: []const u8, chunk_name: [:0]const u8) Error!i64 {
        if (self.api.load_buffer(self.state, source.ptr, source.len, chunk_name.ptr, null) != 0) {
            self.discardStack();
            return error.LoadFailed;
        }
        if (self.protectedCall(0, 1) != 0) {
            self.discardStack();
            return error.CallFailed;
        }
        var is_number: c_int = 0;
        const value = self.api.to_integer(self.state, -1, &is_number);
        self.discardStack();
        if (is_number == 0) return error.InvalidResult;
        return value;
    }

    pub fn stackDepth(self: *const Vm) usize {
        return @intCast(@max(self.api.get_top(self.state), 0));
    }

    pub const LuaType = enum(c_int) {
        none = -1,
        nil = 0,
        boolean = 1,
        light_userdata = 2,
        number = 3,
        string = 4,
        table = 5,
        function = 6,
        userdata = 7,
        thread = 8,
    };

    /// Evaluate a chunk and leave exactly one returned value on the stack.
    /// The caller owns the stack discipline and must call `setTop(0)` when
    /// finished reading it.
    pub fn evalValue(self: *Vm, source: []const u8, chunk_name: [:0]const u8) Error!void {
        if (self.api.load_buffer(self.state, source.ptr, source.len, chunk_name.ptr, null) != 0) {
            std.log.err("Lua load failed: {s}", .{self.string(-1) orelse "unknown Lua error"});
            self.discardStack();
            return error.LoadFailed;
        }
        if (self.protectedCall(0, 1) != 0) {
            std.log.err("Lua call failed: {s}", .{self.string(-1) orelse "unknown Lua error"});
            self.discardStack();
            return error.CallFailed;
        }
    }

    pub fn luaType(self: *const Vm, index: c_int) LuaType {
        return @enumFromInt(self.api.type_of(self.state, index));
    }

    pub fn getField(self: *Vm, index: c_int, name: [:0]const u8) void {
        _ = self.api.get_field(self.state, index, name.ptr);
    }

    pub fn getGlobal(self: *Vm, name: [:0]const u8) void {
        _ = self.api.get_global(self.state, name.ptr);
    }

    pub fn setField(self: *Vm, index: c_int, name: [:0]const u8) void {
        self.api.set_field(self.state, index, name.ptr);
    }

    pub fn rawGetInteger(self: *Vm, index: c_int, item: i64) void {
        _ = self.api.raw_get_i(self.state, index, item);
    }

    pub fn rawSetInteger(self: *Vm, index: c_int, item: i64) void {
        self.api.raw_set_i(self.state, index, item);
    }

    pub fn createTable(self: *Vm, array_items: usize, fields: usize) void {
        self.api.create_table(self.state, @intCast(array_items), @intCast(fields));
    }

    pub fn pushNil(self: *Vm) void {
        self.api.push_nil(self.state);
    }

    pub fn pushInteger(self: *Vm, value: i64) void {
        self.api.push_integer(self.state, value);
    }

    pub fn pushNumber(self: *Vm, value: f64) void {
        self.api.push_number(self.state, value);
    }

    pub fn pushString(self: *Vm, value: []const u8) void {
        _ = self.api.push_lstring_value(self.state, value.ptr, value.len);
    }

    pub fn call(self: *Vm, arguments: u31, results: u31) Error!void {
        if (self.protectedCall(@intCast(arguments), @intCast(results)) != 0)
            return error.CallFailed;
    }

    pub fn rawLength(self: *const Vm, index: c_int) usize {
        return self.api.raw_len(self.state, index);
    }

    pub fn integer(self: *const Vm, index: c_int) ?i64 {
        var is_number: c_int = 0;
        const value = self.api.to_integer(self.state, index, &is_number);
        return if (is_number == 0) null else value;
    }

    pub fn number(self: *const Vm, index: c_int) ?f64 {
        var is_number: c_int = 0;
        const value = self.api.to_number(self.state, index, &is_number);
        return if (is_number == 0) null else value;
    }

    pub fn boolean(self: *const Vm, index: c_int) ?bool {
        if (self.luaType(index) != .boolean) return null;
        return self.api.to_boolean(self.state, index) != 0;
    }

    pub fn string(self: *const Vm, index: c_int) ?[]const u8 {
        var length: usize = 0;
        const value = self.api.to_lstring(self.state, index, &length) orelse return null;
        return value[0..length];
    }

    pub fn setTop(self: *Vm, top: c_int) void {
        self.api.set_top(self.state, top);
    }

    fn discardStack(self: *Vm) void {
        self.api.set_top(self.state, 0);
    }

    fn protectedCall(self: *Vm, arguments: c_int, results: c_int) c_int {
        return self.callbackApi().protectedCall(self, arguments, results);
    }
};

threadlocal var active_vm: ?*Vm = null;

fn instructionHook(state: *State, _: *anyopaque) callconv(.c) void {
    const vm = active_vm orelse return;
    const hook = vm.instruction_hook orelse return;
    if (hook(vm.instruction_context, vm.instruction_granularity)) return;
    _ = vm.api.push_lstring(state, "Lua instruction budget exceeded", 31);
    _ = vm.api.lua_error(state);
}

test "protected Lua chunks execute and leave no stack residue" {
    var vm = try Vm.init(true);
    defer vm.deinit();

    try std.testing.expectEqual(@as(i64, 5), try vm.evalInteger("return 2 + 3", "=test"));
    try std.testing.expectEqual(@as(usize, 0), vm.stackDepth());
    try vm.run("local value = 7", "=test");
    try std.testing.expectEqual(@as(usize, 0), vm.stackDepth());
}

test "load and call failures are protected" {
    var vm = try Vm.init(false);
    defer vm.deinit();

    try std.testing.expectError(error.LoadFailed, vm.run("function", "=bad"));
    try std.testing.expectError(error.CallFailed, vm.run("error('callback failed')", "=bad"));
    try std.testing.expectEqual(@as(usize, 0), vm.stackDepth());
}

test "instruction hook aborts an unbounded Lua chunk" {
    var vm = try Vm.init(true);
    defer vm.deinit();
    const Probe = struct {
        calls: u32 = 0,
        fn hook(raw: ?*anyopaque, _: u64) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls < 3;
        }
    };
    var probe = Probe{};
    try vm.setInstructionHook(Probe.hook, &probe, 1);
    defer vm.clearInstructionHook();
    try std.testing.expectError(error.CallFailed, vm.run("while true do end", "=loop"));
    try std.testing.expect(probe.calls >= 3);
}
