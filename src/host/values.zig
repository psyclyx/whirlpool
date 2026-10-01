//! Building script values by hand: for tools and tests that feed a surface
//! program the services a host would (`desktop`, measurement sources, ...).
//! Everything is allocated in the given arena.

const std = @import("std");
const script = @import("whirlpool-script");

pub const Value = script.program_loader.Value;

pub const Builder = struct {
    arena: std.mem.Allocator,

    /// `fields` is a tuple of `.{ "key", value }` pairs; values may be a
    /// `Value`, a number, a bool, or a string.
    pub fn object(self: Builder, fields: anytype) Value {
        const info = @typeInfo(@TypeOf(fields)).@"struct".fields;
        const out = self.arena.alloc(Value.Field, info.len) catch @panic("out of memory");
        inline for (info, 0..) |field, index| {
            const pair = @field(fields, field.name);
            out[index] = .{ .key = pair[0], .value = self.from(pair[1]) };
        }
        return .{ .object = out };
    }

    pub fn array(self: Builder, items: []const Value) Value {
        return .{ .array = self.arena.dupe(Value, items) catch @panic("out of memory") };
    }

    pub fn numbers(self: Builder, items: []const f64) Value {
        const out = self.arena.alloc(Value, items.len) catch @panic("out of memory");
        for (items, out) |item, *value| value.* = .{ .number = item };
        return .{ .array = out };
    }

    pub fn from(_: Builder, value: anytype) Value {
        const T = @TypeOf(value);
        if (T == Value) return value;
        if (T == bool) return .{ .boolean = value };
        switch (@typeInfo(T)) {
            .int, .comptime_int => return .{ .number = @floatFromInt(value) },
            .float, .comptime_float => return .{ .number = value },
            .pointer => return .{ .string = value },
            else => @compileError("cannot build a script value from " ++ @typeName(T)),
        }
    }
};

/// Sample times for `count` samples `every` milliseconds apart, the newest at
/// `now`.
pub fn times(arena: std.mem.Allocator, now: f64, every: f64, count: usize) []f64 {
    const out = arena.alloc(f64, count) catch @panic("out of memory");
    for (out, 0..) |*time, index| time.* = now - every * @as(f64, @floatFromInt(count - 1 - index));
    return out;
}

/// The running total of `rates` (per second) sampled `every` milliseconds:
/// what a cumulative counter source reports.
pub fn counter(arena: std.mem.Allocator, rates: []const f64, every: f64) []f64 {
    const out = arena.alloc(f64, rates.len) catch @panic("out of memory");
    var total: f64 = 0;
    for (rates, out) |rate, *value| {
        total += rate * every / 1000;
        value.* = total;
    }
    return out;
}
