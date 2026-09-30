//! Borrowed views and owned checkpoints over flat WM resource facts.

const std = @import("std");
const ids = @import("../ids.zig");
const types = @import("../types.zig");

pub fn View(comptime World: type) type {
    return struct {
        const Self = @This();
        world: *const World,

        pub fn init(source: *const World) Self {
            return .{ .world = source };
        }

        pub fn epoch(self: Self) u64 {
            return self.world.epoch();
        }

        pub fn getOutput(self: Self, id: ids.OutputId) ?*const types.Output {
            return self.world.getOutput(id);
        }

        pub fn getTag(self: Self, id: ids.TagId) ?*const types.Tag {
            return self.world.getTag(id);
        }

        pub fn getWindow(self: Self, id: ids.WindowId) ?*const types.Window {
            return self.world.getWindow(id);
        }

        pub fn focusedWindow(self: Self) ?ids.WindowId {
            return self.world.focusedWindow();
        }

        pub fn focusedOutput(self: Self) ?ids.OutputId {
            return self.world.focusedOutput();
        }

        pub fn tagAt(self: Self, ordinal: usize) ?ids.TagId {
            return self.world.tagAt(ordinal);
        }

        pub fn outputAt(self: Self, ordinal: usize) ?ids.OutputId {
            return self.world.outputAt(ordinal);
        }

        pub fn windowAt(self: Self, ordinal: usize) ?ids.WindowId {
            return self.world.windowAt(ordinal);
        }

        pub fn firstOutput(self: Self) ?ids.OutputId {
            return self.world.firstOutput();
        }

        pub fn windowOutput(self: Self, id: ids.WindowId) ?ids.OutputId {
            return self.world.windowOutput(id);
        }

        pub fn liveOutputCount(self: Self) usize {
            return self.world.liveOutputCount();
        }

        pub fn liveTagCount(self: Self) usize {
            return self.world.liveTagCount();
        }

        pub fn liveWindowCount(self: Self) usize {
            return self.world.liveWindowCount();
        }

        pub fn validate(self: Self) !void {
            return self.world.validate();
        }
    };
}

pub fn Checkpoint(comptime World: type) type {
    return struct {
        const Self = @This();
        const Storage = struct { world: World };
        allocator: std.mem.Allocator,
        state: *const Storage,

        pub fn init(source: *const World) !Self {
            const storage = try source.allocator.create(Storage);
            errdefer source.allocator.destroy(storage);
            storage.* = .{ .world = try source.cloneState() };
            return .{ .allocator = source.allocator, .state = storage };
        }

        pub fn deinit(self: *Self) void {
            const storage = @constCast(self.state);
            storage.world.deinit();
            self.allocator.destroy(storage);
            self.* = undefined;
        }

        pub fn epoch(self: *const Self) u64 {
            return self.state.world.epoch();
        }

        pub fn getOutput(self: *const Self, id: ids.OutputId) ?*const types.Output {
            return self.state.world.getOutput(id);
        }

        pub fn getTag(self: *const Self, id: ids.TagId) ?*const types.Tag {
            return self.state.world.getTag(id);
        }

        pub fn getWindow(self: *const Self, id: ids.WindowId) ?*const types.Window {
            return self.state.world.getWindow(id);
        }

        pub fn focusedWindow(self: *const Self) ?ids.WindowId {
            return self.state.world.focusedWindow();
        }

        pub fn focusedOutput(self: *const Self) ?ids.OutputId {
            return self.state.world.focusedOutput();
        }

        pub fn tagAt(self: *const Self, ordinal: usize) ?ids.TagId {
            return self.state.world.tagAt(ordinal);
        }

        pub fn outputAt(self: *const Self, ordinal: usize) ?ids.OutputId {
            return self.state.world.outputAt(ordinal);
        }

        pub fn windowAt(self: *const Self, ordinal: usize) ?ids.WindowId {
            return self.state.world.windowAt(ordinal);
        }

        pub fn firstOutput(self: *const Self) ?ids.OutputId {
            return self.state.world.firstOutput();
        }

        pub fn windowOutput(self: *const Self, id: ids.WindowId) ?ids.OutputId {
            return self.state.world.windowOutput(id);
        }

        pub fn liveOutputCount(self: *const Self) usize {
            return self.state.world.liveOutputCount();
        }

        pub fn liveTagCount(self: *const Self) usize {
            return self.state.world.liveTagCount();
        }

        pub fn liveWindowCount(self: *const Self) usize {
            return self.state.world.liveWindowCount();
        }

        pub fn validate(self: *const Self) !void {
            return self.state.world.validate();
        }
    };
}
