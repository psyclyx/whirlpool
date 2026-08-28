//! Lua policy execution for the River host safe point.
//!
//! This is the only River-facing module which knows that the script VM is
//! PUC Lua.  The host coordinator owns when this object is called; this
//! object owns loading, the Lua instruction hook, and the narrow typed bridge
//! from Snapshot to IntentBatch.

const std = @import("std");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");

const LuaState = script.lua_vm.State;
const CFunction = script.lua_vm.CFunction;

pub const Limits = struct {
    max_instructions: u64 = 100_000,
    hook_granularity: u32 = 100,
};

pub const Module = script.program_loader.Module;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    vm: script.lua_vm.Vm,
    program: script.program_loader.Program,
    limits: Limits,
    callback: ?*script.Callback = null,
    snapshot: ?*const script.Snapshot = null,
    intents: ?*script.IntentBatch = null,
    instructions: u64 = 0,
    hook_failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, entry_name: []const u8, modules: []const Module, limits: Limits) !Runtime {
        var vm = try script.lua_vm.Vm.init(true);
        errdefer vm.deinit();
        const loader = script.program_loader.Loader.init(allocator, .{});
        const program = try loader.load(entry_name, modules);
        return .{ .allocator = allocator, .vm = vm, .program = program, .limits = limits };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !Runtime {
        const modules = [_]Module{.{ .name = "main", .source = "return function()\n" ++
            "  local epoch = whirlpool_snapshot_epoch()\n" ++
            "  if epoch < 0 then error('invalid policy snapshot') end\n" ++
            "end" }};
        return init(allocator, "main", &modules, .{});
    }

    pub fn deinit(self: *Runtime) void {
        self.clearHook();
        self.program.deinit();
        self.vm.deinit();
        self.* = undefined;
    }

    pub fn runHook(raw: ?*anyopaque, callback: *script.Callback, snapshot: *const script.Snapshot, intents: *script.IntentBatch) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        self.callback = callback;
        self.snapshot = snapshot;
        self.intents = intents;
        self.instructions = 0;
        self.hook_failed = false;
        current = self;
        defer {
            self.clearHook();
            current = null;
            self.callback = null;
            self.snapshot = null;
            self.intents = null;
        }
        self.install("whirlpool_snapshot_epoch", snapshotEpoch);
        self.install("whirlpool_window_exists", windowExists);
        self.install("whirlpool_focus_window", focusWindow);
        self.install("whirlpool_native_require", nativeRequire);
        try self.vm.setInstructionHook(instructionHook, @ptrCast(self), self.limits.hook_granularity);

        var source = std.ArrayList(u8).empty;
        defer source.deinit(self.allocator);
        const entry = self.program.entryName();
        try source.appendSlice(self.allocator, "local main = whirlpool_native_require(\"");
        try source.appendSlice(self.allocator, entry);
        try source.appendSlice(self.allocator, "\")\nmain()");
        try self.runChunk(source.items, "=whirlpool.river.policy");
        if (self.hook_failed) return error.LuaInstructionLimitExceeded;
    }

    fn runChunk(self: *Runtime, source: []const u8, name: [:0]const u8) !void {
        const lua_state = self.luaState();
        if (self.lua().load_buffer(lua_state, source.ptr, source.len, name.ptr, null) != 0) {
            self.lua().set_top(lua_state, 0);
            return error.LuaLoadFailed;
        }
        if (self.lua().protectedCall(&self.vm, 0, 0) != 0) {
            self.lua().set_top(lua_state, 0);
            return error.LuaPolicyFailed;
        }
    }

    fn install(self: *Runtime, name: [*:0]const u8, function: CFunction) void {
        const lua_state = self.luaState();
        self.lua().push_lightuserdata(lua_state, @ptrCast(self));
        self.lua().push_cclosure(lua_state, function, 1);
        self.lua().set_global(lua_state, name);
    }

    fn clearHook(self: *Runtime) void {
        self.vm.clearInstructionHook();
    }

    fn luaState(self: *Runtime) *LuaState {
        return self.vm.stateHandle();
    }

    fn lua(self: *Runtime) script.lua_vm.CallbackApi {
        return self.vm.callbackApi();
    }

    fn context(state: *LuaState) *Runtime {
        _ = state;
        return current orelse unreachable;
    }

    fn snapshotEpoch(state: *LuaState) callconv(.c) c_int {
        const self = context(state);
        self.lua().push_integer(state, @intCast(self.snapshot.?.epoch()));
        return 1;
    }

    fn windowExists(state: *LuaState) callconv(.c) c_int {
        const self = context(state);
        const id = self.argumentInteger(state) catch return self.raise(state, "window id must be an integer");
        self.lua().push_boolean(state, if (self.snapshot.?.getWindow(@bitCast(id)) != null) 1 else 0);
        return 1;
    }

    fn focusWindow(state: *LuaState) callconv(.c) c_int {
        const self = context(state);
        const id = self.argumentInteger(state) catch return self.raise(state, "window id must be an integer");
        self.callback.?.allocate() catch return self.raise(state, "policy allocation budget exceeded");
        self.intents.?.append(.{ .focus_window = @bitCast(id) }) catch return self.raise(state, "policy intent limit exceeded");
        return 0;
    }

    fn nativeRequire(state: *LuaState) callconv(.c) c_int {
        const self = context(state);
        const entry = self.program.entryName();
        for (self.program.modules) |module| {
            if (!std.mem.eql(u8, module.name, entry)) continue;
            if (self.lua().load_buffer(state, module.source.ptr, module.source.len, "=whirlpool.policy.module", null) != 0)
                return self.raise(state, "policy module load failed");
            if (self.lua().protectedCall(&self.vm, 0, 1) != 0)
                return self.raise(state, "policy module failed");
            return 1;
        }
        return self.raise(state, "policy entry module not found");
    }

    fn raise(self: *Runtime, state: *LuaState, message: []const u8) c_int {
        _ = self.lua().push_lstring(state, message.ptr, message.len);
        return self.lua().lua_error(state);
    }

    fn argumentInteger(self: *Runtime, state: *LuaState) !i64 {
        var is_number: c_int = 0;
        const value = self.lua().to_integer(state, 1, &is_number);
        if (is_number == 0 or value < 0) return error.InvalidPolicyArgument;
        return value;
    }

    threadlocal var current: ?*Runtime = null;
    fn instructionHook(raw: ?*anyopaque, amount: u64) callconv(.c) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        self.instructions += amount;
        self.callback.?.step(amount) catch {
            self.hook_failed = true;
            return false;
        };
        return true;
    }
};

test "default Lua policy executes at a compositor-free safe point" {
    var runtime = try Runtime.initDefault(std.testing.allocator);
    defer runtime.deinit();
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    var snapshot = world.view();
    var callback: script.Callback = .{};
    try callback.begin(.wm_policy, .{ .max_steps = 10_000 });
    defer callback.end();
    var intents = script.IntentBatch.init(std.testing.allocator, 4);
    defer intents.deinit();
    try Runtime.runHook(@ptrCast(&runtime), &callback, &snapshot, &intents);
    try std.testing.expectEqual(@as(usize, 0), intents.count());
}
