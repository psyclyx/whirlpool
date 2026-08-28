//! Generation-checked identities and owned slot storage.

const std = @import("std");

pub const Kind = enum { node, column, tag, output, window };
pub const NodeId = Id(.node);
pub const ColumnId = Id(.column);
pub const TagId = Id(.tag);
pub const OutputId = Id(.output);
pub const WindowId = Id(.window);

pub fn Id(comptime id_kind: Kind) type {
    return packed struct(u64) {
        slot: u32,
        generation: u32,

        pub const kind = id_kind;
        pub const invalid: @This() = .{ .slot = std.math.maxInt(u32), .generation = 0 };

        /// Construct an identity from its storage coordinates.
        pub fn init(slot: u32, generation: u32) @This() {
            std.debug.assert(slot != std.math.maxInt(u32));
            std.debug.assert(generation != 0);
            return .{ .slot = slot, .generation = generation };
        }

        /// Construct an identity from its storage coordinates.
        pub fn fromParts(slot: u32, generation: u32) @This() {
            return init(slot, generation);
        }

        /// Return the stable integer representation of this identity.
        pub fn raw(self: @This()) u64 {
            return @bitCast(self);
        }

        /// Report whether this value can identify a live slot.
        pub fn isValid(self: @This()) bool {
            return self.generation != 0 and self.slot != std.math.maxInt(u32);
        }
    };
}

/// SlotStore owns values and makes stale IDs unresolvable after destruction.
/// It does not expose mutation to the kernel boundary; World is its owner.
pub fn SlotStore(comptime Value: type, comptime Identity: type) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            generation: u32 = 1,
            value: ?Value = null,
        };

        slots: std.ArrayList(Slot) = .empty,
        free_slots: std.ArrayList(u32) = .empty,
        allocator: std.mem.Allocator = std.heap.page_allocator,

        /// Initialize an empty store owned by allocator.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Release every live value and all slot storage.
        pub fn deinit(self: *Self) void {
            self.assertValid();
            for (self.slots.items) |*slot| {
                if (slot.value) |*value| deinitValue(Value, self.allocator, value);
            }
            self.slots.deinit(self.allocator);
            self.free_slots.deinit(self.allocator);
            self.* = undefined;
        }

        /// Insert a value and return its generation-checked identity.
        pub fn insert(self: *Self, value: Value) !Identity {
            self.assertValid();
            if (self.free_slots.items.len != 0) {
                const index = self.free_slots.pop().?;
                const slot = &self.slots.items[index];
                std.debug.assert(slot.value == null);
                var owned = value;
                assignId(Value, &owned, Identity.init(index, slot.generation));
                slot.value = owned;
                const id = Identity.init(index, slot.generation);
                self.assertValid();
                std.debug.assert(self.getConst(id) != null);
                return id;
            }
            const index = std.math.cast(u32, self.slots.items.len) orelse return error.IdSpaceExhausted;
            var owned = value;
            assignId(Value, &owned, Identity.init(index, 1));
            try self.slots.append(self.allocator, .{ .value = owned });
            const id = Identity.init(index, 1);
            self.assertValid();
            std.debug.assert(self.getConst(id) != null);
            return id;
        }

        /// Resolve a live identity to a mutable value.
        pub fn get(self: *Self, id: Identity) ?*Value {
            self.assertMetadata();
            const slot = self.getSlotMut(id) orelse return null;
            return &slot.value.?;
        }

        /// Resolve a live identity to an immutable value.
        pub fn getConst(self: *const Self, id: Identity) ?*const Value {
            self.assertMetadata();
            const slot = self.getSlot(id) orelse return null;
            return &slot.value.?;
        }

        /// Report whether id currently resolves to a live value.
        pub fn contains(self: *const Self, id: Identity) bool {
            return self.getConst(id) != null;
        }

        /// Remove a value without deinitializing it and invalidate its identity.
        pub fn remove(self: *Self, id: Identity) !Value {
            self.assertValid();
            const slot = self.getSlotMut(id) orelse return error.StaleId;
            const value = slot.value orelse return error.StaleId;
            try self.free_slots.append(self.allocator, id.slot);
            slot.value = null;
            slot.generation = nextGeneration(slot.generation);
            self.assertValid();
            std.debug.assert(self.getConst(id) == null);
            return value;
        }

        /// Remove and deinitialize a live value.
        pub fn discard(self: *Self, id: Identity) !void {
            var value = try self.remove(id);
            deinitValue(Value, self.allocator, &value);
        }

        /// Return the number of occupied slots.
        pub fn liveCount(self: *const Self) usize {
            self.assertMetadata();
            var count: usize = 0;
            for (self.slots.items) |slot| {
                if (slot.value != null) count += 1;
            }
            std.debug.assert(count + self.free_slots.items.len == self.slots.items.len);
            return count;
        }

        /// Deep-copy this store while preserving every identity.
        pub fn clone(self: *const Self) !Self {
            self.assertValid();
            const allocator = self.allocator;
            var copy: Self = .{ .allocator = allocator };
            errdefer copy.deinit();
            try copy.slots.ensureTotalCapacity(allocator, self.slots.items.len);
            for (self.slots.items) |slot| {
                var slot_copy = slot;
                slot_copy.value = if (slot.value) |value|
                    try cloneValue(Value, allocator, &value)
                else
                    null;
                copy.slots.appendAssumeCapacity(slot_copy);
            }
            try copy.free_slots.appendSlice(allocator, self.free_slots.items);
            copy.assertValid();
            std.debug.assert(copy.liveCount() == self.liveCount());
            return copy;
        }

        fn assertMetadata(self: *const Self) void {
            std.debug.assert(self.free_slots.items.len <= self.slots.items.len);
        }

        fn assertValid(self: *const Self) void {
            if (!std.debug.runtime_safety) return;
            self.assertMetadata();

            var vacant_count: usize = 0;
            for (self.slots.items, 0..) |slot, index| {
                std.debug.assert(slot.generation != 0);
                if (slot.value != null) continue;
                vacant_count += 1;
                std.debug.assert(std.mem.count(u32, self.free_slots.items, &.{@intCast(index)}) == 1);
            }
            std.debug.assert(vacant_count == self.free_slots.items.len);
            for (self.free_slots.items) |index| {
                std.debug.assert(index < self.slots.items.len);
                std.debug.assert(self.slots.items[index].value == null);
            }
        }

        fn getSlot(self: *const Self, id: Identity) ?*const Slot {
            if (!id.isValid() or id.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.slot];
            if (slot.generation != id.generation or slot.value == null) return null;
            return slot;
        }

        fn getSlotMut(self: *Self, id: Identity) ?*Slot {
            if (!id.isValid() or id.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.slot];
            if (slot.generation != id.generation or slot.value == null) return null;
            return slot;
        }
    };
}

pub fn Store(comptime Value: type, comptime kind: Kind) type {
    return SlotStore(Value, Id(kind));
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

fn deinitValue(comptime Value: type, allocator: std.mem.Allocator, value: *Value) void {
    if (comptime @hasDecl(Value, "deinit")) value.deinit(allocator);
}

fn cloneValue(comptime Value: type, allocator: std.mem.Allocator, value: *const Value) !Value {
    if (comptime @hasDecl(Value, "clone")) return try value.clone(allocator);
    return value.*;
}
fn assignId(comptime Value: type, value: *Value, id: anytype) void {
    if (comptime @hasField(Value, "id")) value.id = id;
}

test "stale IDs cannot address a reused slot" {
    const Value = struct { number: u32 };
    var store = SlotStore(Value, WindowId).init(std.testing.allocator);
    const first = try store.insert(.{ .number = 1 });
    _ = try store.remove(first);
    const second = try store.insert(.{ .number = 2 });
    defer store.deinit();
    try std.testing.expect(store.getConst(first) == null);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.generation != second.generation);
}
