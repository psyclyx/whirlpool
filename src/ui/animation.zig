//! Host-clock driven animation, independent from callback delivery.

const std = @import("std");
const signal_api = @import("signal.zig");

const Allocator = std.mem.Allocator;

pub fn Target(comptime T: type) type {
    return struct {
        const Self = @This();
        const ValueSignal = signal_api.Signal(T);

        pub const Interpolator = *const fn (from: T, to: T, progress: f32) T;
        pub const Sample = struct {
            value: T,
            progress: f32,
            active: bool,
            done: bool,
        };

        value_signal: ValueSignal,
        from: T,
        to: T,
        interpolator: Interpolator,
        start_ns: u64 = 0,
        duration_ns: u64 = 0,
        last_sample_ns: u64 = 0,
        active: bool = false,
        has_timeline: bool = false,

        pub fn init(allocator: Allocator, initial: T, interpolator: Interpolator) Self {
            return .{
                .value_signal = ValueSignal.init(allocator, initial),
                .from = initial,
                .to = initial,
                .interpolator = interpolator,
            };
        }

        pub fn initLinear(allocator: Allocator, initial: T) Self {
            return init(allocator, initial, linear);
        }

        pub fn deinit(self: *Self) void {
            self.value_signal.deinit();
        }

        pub fn value(self: *const Self) T {
            return self.value_signal.value();
        }

        pub fn signal(self: *Self) *ValueSignal {
            return &self.value_signal;
        }

        pub fn isActive(self: *const Self) bool {
            return self.active;
        }

        pub fn animate(self: *Self, start_ns: u64, duration_ns: u64, target: T) void {
            self.from = self.value_signal.value();
            self.to = target;
            self.start_ns = start_ns;
            self.duration_ns = duration_ns;
            self.last_sample_ns = start_ns;
            self.has_timeline = true;
            self.active = duration_ns != 0;
            if (duration_ns == 0) _ = self.value_signal.set(target);
        }

        /// Sampling mutates the pending value but never invokes callbacks.
        pub fn sample(self: *Self, now_ns: u64) Sample {
            const now = @max(now_ns, self.last_sample_ns);
            self.last_sample_ns = now;
            if (!self.active) return .{
                .value = self.value_signal.value(),
                .progress = if (self.has_timeline) 1 else 0,
                .active = false,
                .done = self.has_timeline,
            };
            if (now <= self.start_ns) {
                _ = self.value_signal.set(self.from);
                return .{ .value = self.from, .progress = 0, .active = true, .done = false };
            }
            const elapsed = now - self.start_ns;
            if (elapsed >= self.duration_ns) {
                self.active = false;
                _ = self.value_signal.set(self.to);
                return .{ .value = self.to, .progress = 1, .active = false, .done = true };
            }
            const progress: f32 = @floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(self.duration_ns)));
            const next = self.interpolator(self.from, self.to, progress);
            _ = self.value_signal.set(next);
            return .{ .value = next, .progress = progress, .active = true, .done = false };
        }

        pub fn cancel(self: *Self) void {
            self.active = false;
        }

        pub fn linear(from: T, to: T, progress: f32) T {
            if (T != f32) @compileError("animation.Target.linear is only defined for f32; pass an interpolator");
            return from + (to - from) * progress;
        }
    };
}

const TestState = struct {
    calls: usize = 0,
    values: std.ArrayList(f32) = .empty,
};

fn record(context: ?*anyopaque, value: f32) void {
    const state: *TestState = @ptrCast(@alignCast(context.?));
    state.calls += 1;
    state.values.append(std.testing.allocator, value) catch unreachable;
}

test "animation is monotonic, host-clock sampled, and zero duration is immediate" {
    var animation = Target(f32).initLinear(std.testing.allocator, 0);
    defer animation.deinit();
    var state = TestState{};
    defer state.values.deinit(std.testing.allocator);
    const subscription = try animation.signal().subscribe(record, &state);
    defer animation.signal().unsubscribe(subscription);

    animation.animate(100, 100, 10);
    const start = animation.sample(100);
    const middle = animation.sample(150);
    const backwards = animation.sample(120);
    const finish = animation.sample(200);
    try std.testing.expectEqual(@as(f32, 0), start.value);
    try std.testing.expectEqual(@as(f32, 5), middle.value);
    try std.testing.expectEqual(@as(f32, 5), backwards.value);
    try std.testing.expect(finish.done);
    try std.testing.expectEqual(@as(f32, 10), finish.value);
    try std.testing.expectEqual(@as(usize, 0), state.calls);
    try std.testing.expectEqual(@as(usize, 1), animation.signal().flush());

    animation.animate(300, 0, 4);
    try std.testing.expectEqual(@as(f32, 4), animation.value());
    try std.testing.expect(!animation.isActive());
    try std.testing.expectEqual(@as(usize, 1), animation.signal().flush());
    try std.testing.expectEqual(@as(f32, 4), state.values.items[1]);
}
