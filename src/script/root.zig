//! Native callback boundary for the Lua host.
//!
//! This module owns callback safe points and the typed WM values that cross
//! them. Lua stack and platform handles remain embedding concerns.

const std = @import("std");
pub const lua_vm = @import("lua_vm.zig");
pub const wm_bridge = @import("wm_bridge.zig");
pub const layout_projection = @import("layout_projection.zig");
pub const program_loader = @import("program/loader.zig");
pub const config = @import("config.zig");

pub const SafePoint = enum { idle, wm_policy, shell_callback };
pub const CallbackBudget = struct { max_steps: u64 = 100_000, max_allocations: u32 = 4096 };

pub const Callback = struct {
    phase: SafePoint = .idle,
    budget: CallbackBudget = .{},
    steps: u64 = 0,
    allocations: u32 = 0,
    pub fn begin(self: *Callback, phase: SafePoint, budget: CallbackBudget) !void {
        if (phase == .idle or self.phase != .idle) return error.InvalidSafePoint;
        self.* = .{ .phase = phase, .budget = budget };
    }
    pub fn step(self: *Callback, amount: u64) !void {
        if (self.phase == .idle) return error.NoCallback;
        self.steps = std.math.add(u64, self.steps, amount) catch return error.BudgetExceeded;
        if (self.steps > self.budget.max_steps) return error.BudgetExceeded;
    }
    pub fn allocate(self: *Callback) !void {
        if (self.phase == .idle) return error.NoCallback;
        self.allocations = std.math.add(u32, self.allocations, 1) catch return error.BudgetExceeded;
        if (self.allocations > self.budget.max_allocations) return error.BudgetExceeded;
    }
    pub fn end(self: *Callback) void {
        self.* = .{};
    }
};

pub const Snapshot = wm_bridge.Snapshot;
pub const Intent = wm_bridge.Intent;
pub const IntentBatch = wm_bridge.IntentBatch;
pub const LayoutProjection = layout_projection.Projection;

test "callbacks are bounded and cannot nest safe points" {
    var callback: Callback = .{};
    try callback.begin(.wm_policy, .{ .max_steps = 2, .max_allocations = 1 });
    try callback.step(2);
    try std.testing.expectError(error.BudgetExceeded, callback.step(1));
    try std.testing.expectError(error.InvalidSafePoint, callback.begin(.shell_callback, .{}));
    callback.end();
    try callback.begin(.shell_callback, .{});
}

test "intent allocation is accounted at the callback boundary" {
    var callback: Callback = .{};
    try callback.begin(.wm_policy, .{ .max_allocations = 1 });
    var batch = IntentBatch.init(std.testing.allocator, 2);
    defer batch.deinit();
    try callback.allocate();
    try batch.append(.{ .focus_window = .fromParts(4, 1) });
    try std.testing.expectError(error.BudgetExceeded, callback.allocate());
    callback.end();
}

test {
    _ = wm_bridge;
    _ = layout_projection;
    _ = program_loader;
    _ = config;
}
