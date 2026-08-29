//! Transactional scene mutation and targeted invalidation.

const std = @import("std");
const properties = @import("properties.zig");
const tree = @import("tree.zig");

const Allocator = std.mem.Allocator;

pub const SceneDelta = struct {
    allocator: Allocator,
    mutations: std.ArrayList(Mutation) = .empty,

    pub const Mutation = struct {
        node: tree.NodeHandle,
        value: tree.PropertyValue,
    };

    pub fn init(allocator: Allocator) SceneDelta {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SceneDelta) void {
        self.clear();
        self.mutations.deinit(self.allocator);
    }

    pub fn clear(self: *SceneDelta) void {
        for (self.mutations.items) |mutation| freeValue(self.allocator, mutation.value);
        self.mutations.clearRetainingCapacity();
    }

    /// Discard all staged changes. This is the explicit rollback operation for
    /// callers that abandon a callback batch before applying it.
    pub fn rollback(self: *SceneDelta) void {
        self.clear();
    }

    pub fn len(self: *const SceneDelta) usize {
        return self.mutations.items.len;
    }

    /// Stage a property write. A node/property pair occupies one mutation;
    /// later writes replace the earlier value while preserving insertion
    /// order of distinct properties.
    pub fn set(self: *SceneDelta, node: tree.NodeHandle, value: tree.PropertyValue) !void {
        const owned = try cloneValue(self.allocator, value);
        for (self.mutations.items) |*mutation| {
            if (mutation.node.eql(node) and sameProperty(mutation.value, owned)) {
                freeValue(self.allocator, mutation.value);
                mutation.value = owned;
                return;
            }
        }
        errdefer freeValue(self.allocator, owned);
        try self.mutations.append(self.allocator, .{ .node = node, .value = owned });
    }

    pub fn setWidth(self: *SceneDelta, node: tree.NodeHandle, value: ?u32) !void {
        try self.set(node, .{ .width = value });
    }

    pub fn setHeight(self: *SceneDelta, node: tree.NodeHandle, value: ?u32) !void {
        try self.set(node, .{ .height = value });
    }

    pub fn setGap(self: *SceneDelta, node: tree.NodeHandle, value: u32) !void {
        try self.set(node, .{ .gap = value });
    }

    pub fn setPadding(self: *SceneDelta, node: tree.NodeHandle, value: tree.Edges) !void {
        try self.set(node, .{ .padding = value });
    }

    pub fn setFlex(self: *SceneDelta, node: tree.NodeHandle, value: u32) !void {
        try self.set(node, .{ .flex = value });
    }

    pub fn setFill(self: *SceneDelta, node: tree.NodeHandle, value: tree.Color) !void {
        try self.set(node, .{ .fill = value });
    }

    pub fn setRadius(self: *SceneDelta, node: tree.NodeHandle, value: f32) !void {
        try self.set(node, .{ .radius = value });
    }

    pub fn setText(self: *SceneDelta, node: tree.NodeHandle, value: []const u8) !void {
        try self.set(node, .{ .text = value });
    }

    pub fn setIconSource(self: *SceneDelta, node: tree.NodeHandle, value: []const u8) !void {
        try self.set(node, .{ .icon_source = value });
    }

    pub fn setTextColor(self: *SceneDelta, node: tree.NodeHandle, value: tree.Color) !void {
        try self.set(node, .{ .text_color = value });
    }

    pub fn setFontSize(self: *SceneDelta, node: tree.NodeHandle, value: u16) !void {
        try self.set(node, .{ .font_size = value });
    }

    pub fn setOpacity(self: *SceneDelta, node: tree.NodeHandle, value: f32) !void {
        try self.set(node, .{ .opacity = value });
    }

    pub fn setClip(self: *SceneDelta, node: tree.NodeHandle, value: bool) !void {
        try self.set(node, .{ .clip = value });
    }

    pub fn setOffsetX(self: *SceneDelta, node: tree.NodeHandle, value: i32) !void {
        try self.set(node, .{ .offset_x = value });
    }

    /// Validate and apply the complete batch atomically. Text replacements
    /// are allocated before the scene is touched, so allocation failure and
    /// every validation failure leave both values and dirty flags unchanged.
    pub fn apply(self: *SceneDelta, scene: *tree.Scene) !void {
        for (self.mutations.items) |mutation| {
            try scene.validateProperty(mutation.node, mutation.value);
        }

        const prepared = try scene.allocator.alloc(Prepared, self.mutations.items.len);
        for (prepared) |*item| item.* = .{};
        errdefer {
            for (prepared) |item| if (item.bytes) |bytes| scene.allocator.free(bytes);
            scene.allocator.free(prepared);
        }

        for (self.mutations.items, 0..) |mutation, index| {
            const requested = ownedBytes(mutation.value) orelse continue;
            const current = scene.node(mutation.node) orelse return error.StaleNode;
            if (std.mem.eql(u8, currentBytes(current, mutation.value), requested)) continue;
            prepared[index].bytes = try scene.allocator.dupe(u8, requested);
        }

        for (self.mutations.items, 0..) |mutation, index| {
            const owns_bytes = ownedBytes(mutation.value) != null;
            if (owns_bytes and prepared[index].bytes == null) continue;
            const owned_bytes = if (prepared[index].bytes) |bytes| blk: {
                prepared[index].bytes = null;
                break :blk bytes;
            } else if (owns_bytes) blk: {
                break :blk @as(?[]u8, null);
            } else null;
            scene.commitProperty(mutation.node, mutation.value, owned_bytes);
        }

        scene.allocator.free(prepared);
        self.clear();
    }

    const Prepared = struct {
        bytes: ?[]u8 = null,
    };
};

fn sameProperty(a: tree.PropertyValue, b: tree.PropertyValue) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b);
}

fn cloneValue(allocator: Allocator, value: tree.PropertyValue) !tree.PropertyValue {
    return properties.cloneValue(allocator, value);
}

fn freeValue(allocator: Allocator, value: tree.PropertyValue) void {
    properties.freeValue(allocator, value);
}

fn ownedBytes(value: tree.PropertyValue) ?[]const u8 {
    return switch (value) {
        .text => |bytes| bytes,
        .icon_source => |bytes| bytes,
        else => null,
    };
}

fn currentBytes(snapshot: tree.NodeSnapshot, value: tree.PropertyValue) []const u8 {
    return switch (value) {
        .text => snapshot.properties.text,
        .icon_source => snapshot.properties.icon_source,
        else => unreachable,
    };
}

test "scene delta coalesces each property and applies the final values" {
    var scene = tree.Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const root = try mount.create(.row, null);
    const label = try mount.text(root, "old");
    scene.clearDirty();

    var delta = SceneDelta.init(std.testing.allocator);
    defer delta.deinit();
    try delta.setText(label, "middle");
    try delta.setText(label, "final");
    try delta.setOpacity(label, 0.5);
    try delta.setOpacity(label, 0.75);
    try std.testing.expectEqual(@as(usize, 2), delta.len());

    try delta.apply(&scene);
    try std.testing.expectEqual(@as(usize, 0), delta.len());
    try std.testing.expectEqualStrings("final", scene.node(label).?.properties.text);
    try std.testing.expectEqual(@as(f32, 0.75), scene.node(label).?.properties.opacity);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{ .layout = true }), scene.node(root).?.dirty);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{ .layout = true, .paint = true }), scene.node(label).?.dirty);
}

test "rejected deltas roll back every value and dirty flag" {
    var scene = tree.Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const root = try mount.create(.row, null);
    const label = try mount.text(root, "stable");
    scene.clearDirty();

    var delta = SceneDelta.init(std.testing.allocator);
    defer delta.deinit();
    try delta.setText(label, "candidate");
    try delta.setFill(label, tree.Color.rgba(1, 0, 0, 1));

    try std.testing.expectError(error.PropertyNotSupported, delta.apply(&scene));
    try std.testing.expectEqualStrings("stable", scene.node(label).?.properties.text);
    try std.testing.expectEqual(@as(f32, 1), scene.node(label).?.properties.opacity);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{}), scene.node(root).?.dirty);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{}), scene.node(label).?.dirty);
    try std.testing.expectEqual(@as(usize, 2), delta.len());

    delta.rollback();
    try std.testing.expectEqual(@as(usize, 0), delta.len());
}

test "targeted invalidation reaches layout ancestors but not unrelated siblings" {
    var scene = tree.Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const root = try mount.create(.row, null);
    const left = try mount.create(.column, root);
    const left_text = try mount.text(left, "left");
    const right = try mount.create(.column, root);
    const right_text = try mount.text(right, "right");
    scene.clearDirty();

    var delta = SceneDelta.init(std.testing.allocator);
    defer delta.deinit();
    try delta.setTextColor(left_text, tree.Color.rgba(0, 1, 0, 1));
    try delta.apply(&scene);

    try std.testing.expectEqual(@as(tree.DirtyFlags, .{ .paint = true }), scene.node(left_text).?.dirty);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{}), scene.node(left).?.dirty);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{}), scene.node(root).?.dirty);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{}), scene.node(right).?.dirty);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{}), scene.node(right_text).?.dirty);

    delta.setText(left_text, "a longer label") catch unreachable;
    try delta.apply(&scene);
    try std.testing.expect(scene.node(left).?.dirty.layout);
    try std.testing.expect(scene.node(root).?.dirty.layout);
    try std.testing.expect(!scene.node(right).?.dirty.layout);
    try std.testing.expect(!scene.node(right_text).?.dirty.layout);
}

test "stale handles reject a whole delta without touching a recycled node" {
    var scene = tree.Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const old = try mount.text(null, "old");
    try mount.remove(old);
    const fresh = try mount.text(null, "fresh");
    scene.clearDirty();

    var delta = SceneDelta.init(std.testing.allocator);
    defer delta.deinit();
    try delta.setText(old, "must not land");
    try delta.setOpacity(fresh, 0.25);
    try std.testing.expectError(error.StaleNode, delta.apply(&scene));
    try std.testing.expectEqualStrings("fresh", scene.node(fresh).?.properties.text);
    try std.testing.expectEqual(@as(f32, 1), scene.node(fresh).?.properties.opacity);
    try std.testing.expectEqual(@as(tree.DirtyFlags, .{}), scene.node(fresh).?.dirty);
}

test "scene delta releases every staged and prepared allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, deltaAllocationScenario, .{});
}

fn deltaAllocationScenario(allocator: Allocator) !void {
    var scene = tree.Scene.init(allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const label = try mount.text(null, "stable");
    scene.clearDirty();

    var delta = SceneDelta.init(allocator);
    defer delta.deinit();
    try delta.setText(label, "a replacement that needs storage");
    try delta.setOpacity(label, 0.5);
    try delta.apply(&scene);
    if (!std.mem.eql(u8, scene.node(label).?.properties.text, "a replacement that needs storage")) {
        return error.InvalidValue;
    }
}
