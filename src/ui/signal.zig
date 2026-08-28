//! Small native signal primitive for retained UI state.
//!
//! Signals separate mutation from delivery.  A write records one pending
//! invalidation and `flush` delivers the latest value once to each live
//! subscriber in subscription order. This makes the host's callback phase
//! explicit.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const SignalError = Allocator.Error || error{
    Inactive,
    SubscriptionIdExhausted,
};

/// A typed value with deterministic, explicitly owned subscriptions.
pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Callback = *const fn (context: ?*anyopaque, value: T) void;

        pub const Subscription = struct {
            id: u64 = 0,
        };

        const Subscriber = struct {
            id: u64,
            active: bool = false,
            callback: Callback = undefined,
            context: ?*anyopaque = null,
        };

        allocator: Allocator,
        current: T,
        subscribers: std.ArrayList(Subscriber) = .empty,
        version_number: u64 = 0,
        pending: bool = false,
        dispatching: bool = false,
        alive: bool = true,
        next_subscription_id: u64 = 1,

        pub fn init(allocator: Allocator, initial: T) Self {
            return .{
                .allocator = allocator,
                .current = initial,
            };
        }

        pub fn deinit(self: *Self) void {
            if (!self.alive) return;
            self.alive = false;
            self.pending = false;
            self.subscribers.deinit(self.allocator);
        }

        pub fn value(self: *const Self) T {
            return self.current;
        }

        pub fn version(self: *const Self) u64 {
            return self.version_number;
        }

        pub fn hasPendingInvalidation(self: *const Self) bool {
            return self.pending;
        }

        /// Replace the value without invoking callbacks.  Equal writes do
        /// not create another invalidation in the current host phase.
        pub fn set(self: *Self, next: T) bool {
            if (!self.alive) return false;
            if (std.meta.eql(self.current, next)) return false;
            self.current = next;
            self.version_number +|= 1;
            self.pending = true;
            return true;
        }

        /// Mark the signal dirty when the value is externally invalidated.
        pub fn invalidate(self: *Self) void {
            if (!self.alive) return;
            self.version_number +|= 1;
            self.pending = true;
        }

        /// Subscribe in deterministic insertion order.  The returned token
        /// owns only the subscription; disposing it never destroys the
        /// signal or any other subscription.
        pub fn subscribe(self: *Self, callback: Callback, context: ?*anyopaque) SignalError!Subscription {
            if (!self.alive) return error.Inactive;

            if (self.next_subscription_id == 0) return error.SubscriptionIdExhausted;
            self.compactInactive();
            const id = self.next_subscription_id;
            try self.subscribers.append(self.allocator, .{
                .id = id,
                .active = true,
                .callback = callback,
                .context = context,
            });
            self.next_subscription_id +%= 1;
            return .{ .id = id };
        }

        /// Remove a subscription owned by this signal. Tokens contain no raw
        /// owner pointer, so retaining one past signal teardown is harmless.
        pub fn unsubscribe(self: *Self, subscription: Subscription) void {
            self.remove(subscription.id);
        }

        pub fn isSubscribed(self: *const Self, subscription: Subscription) bool {
            return self.isSubscriptionActive(subscription.id);
        }

        pub fn subscriptionCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.subscribers.items) |subscriber| {
                if (subscriber.active) count += 1;
            }
            return count;
        }

        /// Deliver at most one callback per live subscription for all writes
        /// since the previous flush.  Subscribers added during dispatch wait
        /// for the next invalidation, and disposed subscribers are skipped.
        /// No allocation occurs in this method.
        pub fn flush(self: *Self) usize {
            if (!self.alive or !self.pending or self.dispatching) return 0;

            self.pending = false;
            const value_snapshot = self.current;
            const limit = self.subscribers.items.len;
            self.dispatching = true;
            defer {
                self.dispatching = false;
                self.compactInactive();
            }

            var delivered: usize = 0;
            var index: usize = 0;
            while (index < limit) : (index += 1) {
                const subscriber = &self.subscribers.items[index];
                if (!subscriber.active) continue;
                subscriber.callback(subscriber.context, value_snapshot);
                delivered += 1;
            }
            return delivered;
        }

        fn isSubscriptionActive(self: *const Self, id: u64) bool {
            if (!self.alive or id == 0) return false;
            for (self.subscribers.items) |subscriber| {
                if (subscriber.id == id) return subscriber.active;
            }
            return false;
        }

        fn remove(self: *Self, id: u64) void {
            if (!self.alive or id == 0) return;
            for (self.subscribers.items) |*subscriber| {
                if (subscriber.id != id) continue;
                subscriber.active = false;
                subscriber.context = null;
                break;
            }
            if (!self.dispatching) self.compactInactive();
        }

        fn compactInactive(self: *Self) void {
            if (self.dispatching) return;
            var write: usize = 0;
            for (self.subscribers.items) |subscriber| {
                if (!subscriber.active) continue;
                self.subscribers.items[write] = subscriber;
                write += 1;
            }
            self.subscribers.items.len = write;
        }
    };
}

const TestState = struct {
    calls: usize = 0,
    values: std.ArrayList(f32) = .empty,

    fn deinit(self: *TestState, allocator: Allocator) void {
        self.values.deinit(allocator);
    }
};

fn recordF32(context: ?*anyopaque, value: f32) void {
    const state: *TestState = @ptrCast(@alignCast(context.?));
    state.calls += 1;
    state.values.append(std.testing.allocator, value) catch unreachable;
}

test "disposed subscriptions stop delivery and stale tokens cannot remove later subscriptions" {
    var signal = Signal(f32).init(std.testing.allocator, 0);
    defer signal.deinit();

    var first_state = TestState{};
    defer first_state.deinit(std.testing.allocator);
    const first = try signal.subscribe(recordF32, &first_state);
    signal.unsubscribe(first);

    var second_state = TestState{};
    defer second_state.deinit(std.testing.allocator);
    const second = try signal.subscribe(recordF32, &second_state);
    defer signal.unsubscribe(second);
    try std.testing.expect(signal.isSubscribed(second));

    _ = signal.set(1);
    try std.testing.expectEqual(@as(usize, 1), signal.flush());
    try std.testing.expectEqual(@as(usize, 0), first_state.calls);
    try std.testing.expectEqual(@as(usize, 1), second_state.calls);
}

test "writes coalesce into one deterministic invalidation" {
    var signal = Signal(f32).init(std.testing.allocator, 0);
    defer signal.deinit();
    var state = TestState{};
    defer state.deinit(std.testing.allocator);
    const subscription = try signal.subscribe(recordF32, &state);
    defer signal.unsubscribe(subscription);

    _ = signal.set(1);
    _ = signal.set(2);
    _ = signal.set(3);
    try std.testing.expect(signal.hasPendingInvalidation());
    try std.testing.expectEqual(@as(usize, 1), signal.flush());
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(f32, 3), state.values.items[0]);
    try std.testing.expectEqual(@as(usize, 0), signal.flush());
}

test "compaction does not move a later subscription ahead of its peers" {
    var signal = Signal(u32).init(std.testing.allocator, 0);
    defer signal.deinit();

    var order: [4]u32 = undefined;
    var length: usize = 0;
    const Context = struct {
        order: *[4]u32,
        length: *usize,
        marker: u32,

        fn callback(context: ?*anyopaque, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.order[self.length.*] = self.marker;
            self.length.* += 1;
        }
    };

    var first_context = Context{ .order = &order, .length = &length, .marker = 1 };
    var second_context = Context{ .order = &order, .length = &length, .marker = 2 };
    var third_context = Context{ .order = &order, .length = &length, .marker = 3 };
    const first = try signal.subscribe(Context.callback, &first_context);
    const second = try signal.subscribe(Context.callback, &second_context);
    defer signal.unsubscribe(second);
    signal.unsubscribe(first);
    const third = try signal.subscribe(Context.callback, &third_context);
    defer signal.unsubscribe(third);

    _ = signal.set(1);
    try std.testing.expectEqual(@as(usize, 2), signal.flush());
    try std.testing.expectEqualSlices(u32, &[_]u32{ 2, 3 }, order[0..length]);
}

test "subscription allocation failure does not leave a phantom subscriber" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, subscriptionAllocationScenario, .{});
}

fn subscriptionAllocationScenario(allocator: Allocator) !void {
    var signal = Signal(u32).init(allocator, 0);
    defer signal.deinit();
    const subscription = try signal.subscribe(ignoreU32, null);
    defer signal.unsubscribe(subscription);
    try std.testing.expectEqual(@as(usize, 1), signal.subscriptionCount());
}

fn ignoreU32(_: ?*anyopaque, _: u32) void {}
