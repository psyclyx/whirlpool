//! Generation-checked slot allocation for retained UI objects.

const std = @import("std");

pub const Kind = enum { node, mount };

pub fn Handle(comptime kind: Kind) type {
    return struct {
        slot: u32,
        generation: u32,

        pub const arena_kind = kind;
        pub const invalid: @This() = .{ .slot = std.math.maxInt(u32), .generation = 0 };

        pub fn eql(a: @This(), b: @This()) bool {
            return a.slot == b.slot and a.generation == b.generation;
        }

        pub fn isValid(self: @This()) bool {
            return self.generation != 0 and self.slot != invalid.slot;
        }
    };
}

pub fn Arena(comptime Value: type, comptime Identity: type) type {
    return struct {
        const Self = @This();

        pub const State = enum { free, alive, retired };
        pub const Slot = struct {
            generation: u32 = 1,
            state: State = .free,
            next_free: ?u32 = null,
            value: Value = undefined,
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayList(Slot) = .empty,
        first_free: ?u32 = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
        }

        pub fn insert(self: *Self, value: Value) !Identity {
            if (self.first_free) |index| {
                const slot = &self.slots.items[index];
                std.debug.assert(slot.state == .free);
                self.first_free = slot.next_free;
                slot.next_free = null;
                slot.state = .alive;
                slot.value = value;
                return .{ .slot = index, .generation = slot.generation };
            }

            const index = std.math.cast(u32, self.slots.items.len) orelse return error.GenerationExhausted;
            try self.slots.append(self.allocator, .{ .state = .alive, .value = value });
            return .{ .slot = index, .generation = 1 };
        }

        pub fn release(self: *Self, id: Identity) void {
            const slot = &self.slots.items[id.slot];
            std.debug.assert(slot.state == .alive and slot.generation == id.generation);
            slot.value = undefined;
            if (slot.generation == std.math.maxInt(u32)) {
                slot.state = .retired;
                slot.next_free = null;
                return;
            }
            slot.generation += 1;
            slot.state = .free;
            slot.next_free = self.first_free;
            self.first_free = id.slot;
        }

        pub fn get(self: *Self, id: Identity) ?*Value {
            if (!id.isValid() or id.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.slot];
            if (slot.state != .alive or slot.generation != id.generation) return null;
            return &slot.value;
        }

        pub fn getConst(self: *const Self, id: Identity) ?*const Value {
            if (!id.isValid() or id.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.slot];
            if (slot.state != .alive or slot.generation != id.generation) return null;
            return &slot.value;
        }

        pub fn liveCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.slots.items) |slot| if (slot.state == .alive) {
                count += 1;
            };
            return count;
        }
    };
}

test "released slots reject stale handles and are reused in O(1)" {
    const Id = Handle(.node);
    var values = Arena(u32, Id).init(std.testing.allocator);
    defer values.deinit();
    const first = try values.insert(1);
    values.release(first);
    const second = try values.insert(2);
    try std.testing.expect(values.get(first) == null);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expectEqual(@as(u32, 2), values.get(second).?.*);
}
