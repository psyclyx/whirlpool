//! Borrowed views and explicitly owned checkpoints over a WM World.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");

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

        pub fn getColumn(self: Self, id: ids.ColumnId) ?*const types.Column {
            return self.world.getColumn(id);
        }

        pub fn getNode(self: Self, id: ids.NodeId) ?*const types.Node {
            return self.world.getNode(id);
        }

        pub fn getWindow(self: Self, id: ids.WindowId) ?*const types.Window {
            return self.world.getWindow(id);
        }

        pub fn nodeForWindow(self: Self, id: ids.WindowId) ?ids.NodeId {
            return self.world.nodeForWindow(id);
        }

        pub fn tagColumns(self: Self, id: ids.TagId) ?[]const ids.ColumnId {
            return self.world.tagColumns(id);
        }

        pub fn tagAt(self: Self, ordinal: usize) ?ids.TagId {
            return self.world.tagAt(ordinal);
        }

        pub fn firstOutput(self: Self) ?ids.OutputId {
            return self.world.firstOutput();
        }

        pub fn focusedWindow(self: Self, output_id: ids.OutputId) ?ids.WindowId {
            const output = self.getOutput(output_id) orelse return null;
            const tag = self.getTag(output.active_tag) orelse return null;
            return self.focusedWindowInNode(tag.focused orelse return null);
        }

        pub fn validate(self: Self) !void {
            return self.world.validate();
        }

        fn focusedWindowInNode(self: Self, node_id: ids.NodeId) ?ids.WindowId {
            const node = self.getNode(node_id) orelse return null;
            if (node.window) |window| return window;
            if (node.children.items.len == 0 or node.active_child >= node.children.items.len) return null;
            return self.focusedWindowInNode(node.children.items[node.active_child].id);
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

        pub fn getColumn(self: *const Self, id: ids.ColumnId) ?*const types.Column {
            return self.state.world.getColumn(id);
        }

        pub fn getNode(self: *const Self, id: ids.NodeId) ?*const types.Node {
            return self.state.world.getNode(id);
        }

        pub fn getWindow(self: *const Self, id: ids.WindowId) ?*const types.Window {
            return self.state.world.getWindow(id);
        }

        pub fn nodeForWindow(self: *const Self, id: ids.WindowId) ?ids.NodeId {
            return self.state.world.nodeForWindow(id);
        }

        pub fn tagColumns(self: *const Self, id: ids.TagId) ?[]const ids.ColumnId {
            return self.state.world.tagColumns(id);
        }

        pub fn tagAt(self: *const Self, ordinal: usize) ?ids.TagId {
            return self.state.world.tagAt(ordinal);
        }

        pub fn firstOutput(self: *const Self) ?ids.OutputId {
            return self.state.world.firstOutput();
        }

        pub fn focusedWindow(self: *const Self, output_id: ids.OutputId) ?ids.WindowId {
            const output = self.getOutput(output_id) orelse return null;
            const tag = self.getTag(output.active_tag) orelse return null;
            return self.focusedWindowInNode(tag.focused orelse return null);
        }

        pub fn validate(self: *const Self) !void {
            return self.state.world.validate();
        }

        fn focusedWindowInNode(self: *const Self, node_id: ids.NodeId) ?ids.WindowId {
            const node = self.getNode(node_id) orelse return null;
            if (node.window) |window| return window;
            if (node.children.items.len == 0 or node.active_child >= node.children.items.len) return null;
            return self.focusedWindowInNode(node.children.items[node.active_child].id);
        }
    };
}
