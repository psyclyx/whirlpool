//! Throughput from a ring of (time, cumulative bytes) samples.
//!
//! A rate is total bytes moved over the time they took to move across a
//! trailing window. Unlike differencing adjacent samples, this does not jump
//! when one sample arrives early or late, and unlike an exponential average it
//! has a definite memory: a burst leaves the number exactly `window` after it
//! arrived.

const std = @import("std");

pub const WindowedRate = struct {
    const capacity = 64;

    times: [capacity]i128 = [_]i128{0} ** capacity,
    bytes: [capacity]u64 = [_]u64{0} ** capacity,
    len: usize = 0,
    head: usize = 0,

    pub fn push(self: *WindowedRate, time_ns: i128, total_bytes: u64) void {
        self.times[self.head] = time_ns;
        self.bytes[self.head] = total_bytes;
        self.head = (self.head + 1) % capacity;
        self.len = @min(capacity, self.len + 1);
    }

    fn at(self: *const WindowedRate, age: usize) usize {
        // age 0 is the newest sample.
        return (self.head + capacity - 1 - age) % capacity;
    }

    /// Bytes per second over the trailing `window_ns`. Counter resets (a
    /// smaller newest value) read as zero.
    pub fn rate(self: *const WindowedRate, window_ns: i128) f64 {
        if (self.len < 2) return 0;
        const newest = self.at(0);
        var oldest = newest;
        var age: usize = 1;
        while (age < self.len) : (age += 1) {
            const index = self.at(age);
            if (self.times[newest] - self.times[index] > window_ns) break;
            oldest = index;
        }
        const elapsed = self.times[newest] - self.times[oldest];
        if (elapsed <= 0) return 0;
        const moved = self.bytes[newest] -| self.bytes[oldest];
        return @as(f64, @floatFromInt(moved)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
    }
};

const second = std.time.ns_per_s;

test "rate is bytes moved over the window they moved in" {
    var counter = WindowedRate{};
    counter.push(0, 0);
    counter.push(1 * second, 1000);
    counter.push(2 * second, 3000);
    try std.testing.expectApproxEqAbs(@as(f64, 1500), counter.rate(2 * second), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2000), counter.rate(1 * second), 0.001);
}

test "uneven sample spacing does not distort the rate" {
    var counter = WindowedRate{};
    counter.push(0, 0);
    // Two samples arrive back to back, then a long gap; 4000 B/s throughout.
    counter.push(1000 * std.time.ns_per_ms, 4000);
    counter.push(1010 * std.time.ns_per_ms, 4040);
    counter.push(3000 * std.time.ns_per_ms, 12000);
    try std.testing.expectApproxEqAbs(@as(f64, 4000), counter.rate(4 * second), 1);
}

test "a burst leaves the window after exactly the window length" {
    var counter = WindowedRate{};
    var t: i128 = 0;
    var total: u64 = 0;
    counter.push(t, total);
    t += second;
    total += 10_000_000;
    counter.push(t, total);
    try std.testing.expect(counter.rate(2 * second) > 9_000_000);
    for (0..3) |_| {
        t += second;
        counter.push(t, total);
    }
    try std.testing.expectEqual(@as(f64, 0), counter.rate(2 * second));
}

test "counter resets and single samples read as zero" {
    var counter = WindowedRate{};
    try std.testing.expectEqual(@as(f64, 0), counter.rate(second));
    counter.push(0, 5000);
    try std.testing.expectEqual(@as(f64, 0), counter.rate(second));
    counter.push(second, 100);
    try std.testing.expectEqual(@as(f64, 0), counter.rate(2 * second));
}
