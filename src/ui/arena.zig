//! Generation-checked slot allocation for retained UI objects.

const std = @import("std");

pub const Kind = enum { node, mount };

pub fn Handle(comptime kind: Kind) type {
    return struct {
        slot: u32,
        generation: u32,

        pub const arena_kind = kind;
        pub const invalid: @This() = .{ .slot = std.math.maxInt(u32), .generation = 0 };

        /// Compare both slot and generation.
        pub fn eql(a: @This(), b: @This()) bool {
            return a.slot == b.slot and a.generation == b.generation;
        }

        /// Report whether this value can identify an arena slot.
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

        /// Initialize an empty generation-checked arena.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Release arena slot storage after all owned values are handled.
        pub fn deinit(self: *Self) void {
            self.assertValid();
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        /// Insert a value, reusing a free slot when possible.
        pub fn insert(self: *Self, value: Value) !Identity {
            self.assertValid();
            if (self.first_free) |index| {
                const slot = &self.slots.items[index];
                std.debug.assert(slot.state == .free);
                self.first_free = slot.next_free;
                slot.next_free = null;
                slot.state = .alive;
                slot.value = value;
                const id = Identity{ .slot = index, .generation = slot.generation };
                self.assertValid();
                std.debug.assert(self.getConst(id) != null);
                return id;
            }

            const index = std.math.cast(u32, self.slots.items.len) orelse return error.GenerationExhausted;
            try self.slots.append(self.allocator, .{ .state = .alive, .value = value });
            const id = Identity{ .slot = index, .generation = 1 };
            self.assertValid();
            std.debug.assert(self.getConst(id) != null);
            return id;
        }

        /// Release a live identity and invalidate its generation.
        pub fn release(self: *Self, id: Identity) void {
            self.assertValid();
            std.debug.assert(id.isValid());
            std.debug.assert(id.slot < self.slots.items.len);
            const slot = &self.slots.items[id.slot];
            std.debug.assert(slot.state == .alive and slot.generation == id.generation);
            slot.value = undefined;
            if (slot.generation == std.math.maxInt(u32)) {
                slot.state = .retired;
                slot.next_free = null;
                self.assertValid();
                return;
            }
            slot.generation += 1;
            slot.state = .free;
            slot.next_free = self.first_free;
            self.first_free = id.slot;
            self.assertValid();
            std.debug.assert(self.getConst(id) == null);
        }

        /// Resolve a live identity to a mutable value.
        pub fn get(self: *Self, id: Identity) ?*Value {
            self.assertMetadata();
            if (!id.isValid() or id.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.slot];
            if (slot.state != .alive or slot.generation != id.generation) return null;
            return &slot.value;
        }

        /// Resolve a live identity to an immutable value.
        pub fn getConst(self: *const Self, id: Identity) ?*const Value {
            self.assertMetadata();
            if (!id.isValid() or id.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.slot];
            if (slot.state != .alive or slot.generation != id.generation) return null;
            return &slot.value;
        }

        /// Return the number of live arena slots.
        pub fn liveCount(self: *const Self) usize {
            self.assertMetadata();
            var count: usize = 0;
            for (self.slots.items) |slot| if (slot.state == .alive) {
                count += 1;
            };
            return count;
        }

        fn assertMetadata(self: *const Self) void {
            if (self.first_free) |index| std.debug.assert(index < self.slots.items.len);
        }

        fn assertValid(self: *const Self) void {
            if (!std.debug.runtime_safety) return;
            self.assertMetadata();
            var free_count: usize = 0;
            for (self.slots.items, 0..) |slot, index| {
                std.debug.assert(slot.generation != 0);
                switch (slot.state) {
                    .alive, .retired => std.debug.assert(slot.next_free == null),
                    .free => {
                        free_count += 1;
                        std.debug.assert(self.freeOccurrences(@intCast(index)) == 1);
                    },
                }
            }
            var chain_count: usize = 0;
            var current = self.first_free;
            while (current) |index| {
                std.debug.assert(index < self.slots.items.len);
                std.debug.assert(self.slots.items[index].state == .free);
                chain_count += 1;
                std.debug.assert(chain_count <= self.slots.items.len);
                current = self.slots.items[index].next_free;
            }
            std.debug.assert(chain_count == free_count);
        }

        fn freeOccurrences(self: *const Self, target: u32) usize {
            var count: usize = 0;
            var steps: usize = 0;
            var current = self.first_free;
            while (current) |index| {
                std.debug.assert(index < self.slots.items.len);
                if (index == target) count += 1;
                steps += 1;
                std.debug.assert(steps <= self.slots.items.len);
                current = self.slots.items[index].next_free;
            }
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
