//! Retained tree storage and explicit mount ownership.

const std = @import("std");
const arena = @import("arena.zig");
const properties = @import("properties.zig");

const Allocator = std.mem.Allocator;

pub const NodeHandle = arena.Handle(.node);
const MountHandle = arena.Handle(.mount);
pub const NodeKind = properties.NodeKind;
pub const Edges = properties.Edges;
pub const Color = properties.Color;
pub const DirtyFlags = properties.DirtyFlags;
pub const NodeProperties = properties.Snapshot;

pub const NodeSnapshot = struct {
    handle: NodeHandle,
    kind: NodeKind,
    parent: ?NodeHandle,
    properties: NodeProperties,
    dirty: DirtyFlags,
};

pub const PropertyValue = properties.Value;

pub const NodeError = properties.Error || error{
    StaleNode,
    InvalidParent,
    InvalidMount,
    InvalidProperty,
    PropertyNotSupported,
    InvalidValue,
    GenerationExhausted,
};

const Node = struct {
    kind: NodeKind,
    owner: MountHandle,
    parent: ?NodeHandle = null,
    first_child: ?NodeHandle = null,
    last_child: ?NodeHandle = null,
    previous_sibling: ?NodeHandle = null,
    next_sibling: ?NodeHandle = null,
    properties: properties.Owned = .{},
    dirty: DirtyFlags = .{},
};

const Mount = struct {
    parent: ?MountHandle = null,
    anchor: ?NodeHandle = null,
    children: std.ArrayList(MountHandle) = .empty,
    owned_nodes: std.ArrayList(NodeHandle) = .empty,
};

pub const Scene = struct {
    allocator: Allocator,
    nodes: arena.Arena(Node, NodeHandle),
    mounts: arena.Arena(Mount, MountHandle),
    first_root: ?NodeHandle = null,
    last_root: ?NodeHandle = null,

    pub fn init(allocator: Allocator) Scene {
        return .{
            .allocator = allocator,
            .nodes = .init(allocator),
            .mounts = .init(allocator),
        };
    }

    pub fn deinit(self: *Scene) void {
        while (self.liveMountCount() != 0) {
            var candidate: ?MountHandle = null;
            for (self.mounts.slots.items, 0..) |mount_slot, index| {
                if (mount_slot.state != .alive) continue;
                if (mount_slot.value.parent == null) {
                    candidate = .{
                        .slot = @intCast(index),
                        .generation = mount_slot.generation,
                    };
                    break;
                }
                if (candidate == null) {
                    candidate = .{
                        .slot = @intCast(index),
                        .generation = mount_slot.generation,
                    };
                }
            }
            if (candidate) |id| self.destroyMount(id) else break;
        }

        self.mounts.deinit();
        self.nodes.deinit();
    }

    pub fn mount(self: *Scene) !MountContext {
        const id = try self.allocateMount(null, null);
        return .{ .scene = self, .id = id };
    }

    pub fn liveNodeCount(self: *const Scene) usize {
        return self.nodes.liveCount();
    }

    pub fn liveMountCount(self: *const Scene) usize {
        return self.mounts.liveCount();
    }

    pub fn node(self: *const Scene, handle: NodeHandle) ?NodeSnapshot {
        const stored = self.lookupNode(handle) orelse return null;
        return .{
            .handle = handle,
            .kind = stored.kind,
            .parent = stored.parent,
            .properties = stored.properties.snapshot(),
            .dirty = stored.dirty,
        };
    }

    /// Copy the direct children in retained order. Passing null returns the
    /// scene roots. The returned handle array belongs to the caller.
    pub fn childrenAlloc(self: *const Scene, allocator: Allocator, parent: ?NodeHandle) (NodeError || Allocator.Error)![]NodeHandle {
        if (parent) |parent_handle| _ = self.lookupNode(parent_handle) orelse return error.StaleNode;

        const first = if (parent) |parent_handle|
            (self.lookupNode(parent_handle) orelse unreachable).first_child
        else
            self.first_root;
        var count: usize = 0;
        var current = first;
        while (current) |handle| {
            count += 1;
            current = (self.lookupNode(handle) orelse return error.StaleNode).next_sibling;
        }

        const result = try allocator.alloc(NodeHandle, count);
        current = first;
        var written: usize = 0;
        while (current) |handle| {
            result[written] = handle;
            written += 1;
            current = (self.lookupNode(handle) orelse unreachable).next_sibling;
        }
        return result;
    }

    pub fn dirtyFlags(self: *const Scene, handle: NodeHandle) NodeError!DirtyFlags {
        return (self.lookupNode(handle) orelse return error.StaleNode).dirty;
    }

    pub fn clearDirty(self: *Scene) void {
        for (self.nodes.slots.items) |*slot| {
            if (slot.state == .alive) slot.value.dirty = .{};
        }
    }

    /// Return stable, caller-owned snapshots for the currently dirty nodes.
    /// Text bytes are copied so a target may retain the result across later
    /// scene mutations. The caller releases the result with freeSnapshots.
    pub fn snapshotDirtyAlloc(self: *const Scene, allocator: Allocator) ![]NodeSnapshot {
        var count: usize = 0;
        for (self.nodes.slots.items) |slot| {
            if (slot.state == .alive and isDirty(slot.value.dirty)) count += 1;
        }

        const snapshots = try allocator.alloc(NodeSnapshot, count);
        var written: usize = 0;
        errdefer {
            for (snapshots[0..written]) |snapshot| freeSnapshotText(allocator, snapshot);
            allocator.free(snapshots);
        }

        for (self.nodes.slots.items, 0..) |slot, index| {
            if (slot.state != .alive or !isDirty(slot.value.dirty)) continue;
            const handle = NodeHandle{
                .slot = @intCast(index),
                .generation = slot.generation,
            };
            snapshots[written] = try self.copySnapshot(allocator, handle);
            written += 1;
        }
        return snapshots;
    }

    pub fn freeSnapshots(allocator: Allocator, snapshots: []NodeSnapshot) void {
        for (snapshots) |snapshot| freeSnapshotText(allocator, snapshot);
        allocator.free(snapshots);
    }

    pub fn validateProperty(self: *const Scene, handle: NodeHandle, value: PropertyValue) NodeError!void {
        const stored = self.lookupNode(handle) orelse return error.StaleNode;
        try properties.validate(stored.kind, value);
    }

    /// Apply one already-validated property. SceneDelta performs the
    /// transaction-level validation and allocation before calling this.
    pub fn applyProperty(self: *Scene, handle: NodeHandle, value: PropertyValue, owned_text: ?[]u8) NodeError!void {
        const stored = self.lookupNodeMut(handle) orelse return error.StaleNode;
        try properties.validate(stored.kind, value);
        switch (value) {
            .text => |requested| {
                if (owned_text == null and !std.mem.eql(u8, stored.properties.text, requested)) {
                    return error.InvalidValue;
                }
            },
            else => {},
        }
        self.commitProperty(handle, value, owned_text);
    }

    /// Commit a property after the caller has validated the node and prepared
    /// all fallible allocations. Keeping this phase infallible is what makes a
    /// SceneDelta's mutation phase atomic.
    pub fn commitProperty(self: *Scene, handle: NodeHandle, value: PropertyValue, owned_text: ?[]u8) void {
        const stored = self.lookupNodeMut(handle) orelse unreachable;
        stored.properties.commit(self.allocator, value, owned_text);

        const dirty = properties.metadata(value).dirty;
        stored.dirty.layout = stored.dirty.layout or dirty.layout;
        stored.dirty.paint = stored.dirty.paint or dirty.paint;
        if (dirty.layout) self.markLayoutAncestors(stored.parent);
    }

    fn markLayoutAncestors(self: *Scene, start: ?NodeHandle) void {
        var current = start;
        while (current) |handle| {
            const stored = self.lookupNodeMut(handle) orelse break;
            stored.dirty.layout = true;
            current = stored.parent;
        }
    }

    fn allocateNode(self: *Scene, node_value: Node) !NodeHandle {
        return self.nodes.insert(node_value);
    }

    fn releaseNodeSlot(self: *Scene, handle: NodeHandle) void {
        const slot = &self.nodes.slots.items[handle.slot];
        if (slot.value.properties.text.len != 0) self.allocator.free(slot.value.properties.text);
        self.nodes.release(handle);
    }

    fn allocateMount(self: *Scene, parent: ?MountHandle, anchor: ?NodeHandle) !MountHandle {
        return self.mounts.insert(.{
            .parent = parent,
            .anchor = anchor,
        });
    }

    fn releaseMountSlot(self: *Scene, id: MountHandle) void {
        var slot = &self.mounts.slots.items[id.slot];
        slot.value.children.deinit(self.allocator);
        slot.value.owned_nodes.deinit(self.allocator);
        self.mounts.release(id);
    }

    fn destroyMount(self: *Scene, id: MountHandle) void {
        const mount_slot = self.lookupMount(id) orelse return;

        var child_index = mount_slot.children.items.len;
        while (child_index != 0) {
            child_index -= 1;
            self.destroyMount(mount_slot.children.items[child_index]);
        }

        var node_index = mount_slot.owned_nodes.items.len;
        while (node_index != 0) {
            node_index -= 1;
            const handle = mount_slot.owned_nodes.items[node_index];
            if (self.lookupNode(handle) != null) self.destroyNode(handle);
        }

        const parent = mount_slot.parent;
        if (parent) |parent_id| {
            if (self.lookupMountMut(parent_id)) |parent_mount| {
                removeMountChild(parent_mount, id);
            }
        }
        self.releaseMountSlot(id);
    }

    fn destroyNode(self: *Scene, handle: NodeHandle) void {
        const stored = self.lookupNode(handle) orelse return;
        self.destroyAnchoredMounts(handle);

        var child = stored.first_child;
        while (child) |child_handle| {
            const next = (self.lookupNode(child_handle) orelse break).next_sibling;
            self.destroyNode(child_handle);
            child = next;
        }

        const parent = stored.parent;
        self.detachNode(handle);
        if (parent) |parent_handle| self.markLayoutAncestors(parent_handle);
        self.releaseNodeSlot(handle);
    }

    fn destroyAnchoredMounts(self: *Scene, anchor: NodeHandle) void {
        var index: usize = 0;
        while (index < self.mounts.slots.items.len) {
            const slot = &self.mounts.slots.items[index];
            if (slot.state == .alive and slot.value.anchor != null and slot.value.anchor.?.eql(anchor)) {
                self.destroyMount(.{
                    .slot = @intCast(index),
                    .generation = slot.generation,
                });
                continue;
            }
            index += 1;
        }
    }

    fn detachNode(self: *Scene, handle: NodeHandle) void {
        const stored = self.lookupNode(handle) orelse return;
        if (stored.parent) |parent_handle| {
            if (self.lookupNodeMut(parent_handle)) |parent| {
                if (parent.first_child != null and parent.first_child.?.eql(handle)) {
                    parent.first_child = stored.next_sibling;
                }
                if (parent.last_child != null and parent.last_child.?.eql(handle)) {
                    parent.last_child = stored.previous_sibling;
                }
            }
        } else {
            if (self.first_root != null and self.first_root.?.eql(handle)) {
                self.first_root = stored.next_sibling;
            }
            if (self.last_root != null and self.last_root.?.eql(handle)) {
                self.last_root = stored.previous_sibling;
            }
        }
        if (stored.previous_sibling) |previous| {
            if (self.lookupNodeMut(previous)) |sibling| sibling.next_sibling = stored.next_sibling;
        }
        if (stored.next_sibling) |next| {
            if (self.lookupNodeMut(next)) |sibling| sibling.previous_sibling = stored.previous_sibling;
        }
    }

    fn lookupNode(self: *const Scene, handle: NodeHandle) ?*const Node {
        return self.nodes.getConst(handle);
    }

    fn lookupNodeMut(self: *Scene, handle: NodeHandle) ?*Node {
        return self.nodes.get(handle);
    }

    fn lookupMount(self: *const Scene, id: MountHandle) ?*const Mount {
        return self.mounts.getConst(id);
    }

    fn lookupMountMut(self: *Scene, id: MountHandle) ?*Mount {
        return self.mounts.get(id);
    }

    fn copySnapshot(self: *const Scene, allocator: Allocator, handle: NodeHandle) !NodeSnapshot {
        const stored = self.lookupNode(handle) orelse return error.StaleNode;
        var snapshot = NodeSnapshot{
            .handle = handle,
            .kind = stored.kind,
            .parent = stored.parent,
            .properties = stored.properties.snapshot(),
            .dirty = stored.dirty,
        };
        if (stored.properties.text.len != 0) {
            const text = try allocator.dupe(u8, stored.properties.text);
            snapshot.properties.text = text;
        }
        return snapshot;
    }

    fn liveMount(self: *Scene, id: MountHandle) NodeError!*Mount {
        return self.lookupMountMut(id) orelse error.InvalidMount;
    }

    fn attachNode(self: *Scene, handle: NodeHandle, parent_handle: ?NodeHandle) NodeError!void {
        const stored = self.lookupNodeMut(handle) orelse return error.StaleNode;
        stored.parent = parent_handle;
        if (parent_handle) |parent_id| {
            const parent = self.lookupNodeMut(parent_id) orelse return error.InvalidParent;
            stored.previous_sibling = parent.last_child;
            if (parent.last_child) |last| {
                (self.lookupNodeMut(last) orelse return error.InvalidParent).next_sibling = handle;
            } else {
                parent.first_child = handle;
            }
            parent.last_child = handle;
        } else {
            stored.previous_sibling = self.last_root;
            if (self.last_root) |last| {
                (self.lookupNodeMut(last) orelse return error.InvalidParent).next_sibling = handle;
            } else {
                self.first_root = handle;
            }
            self.last_root = handle;
        }
    }

    fn isAncestorOrSelf(self: *const Scene, possible_ancestor: MountHandle, mount_id: MountHandle) bool {
        var current: ?MountHandle = mount_id;
        while (current) |id| {
            if (id.slot == possible_ancestor.slot and id.generation == possible_ancestor.generation) return true;
            current = (self.lookupMount(id) orelse return false).parent;
        }
        return false;
    }

    fn removeMountChild(mount_slot: *Mount, child: MountHandle) void {
        for (mount_slot.children.items, 0..) |candidate, index| {
            if (candidate.slot == child.slot and candidate.generation == child.generation) {
                _ = mount_slot.children.orderedRemove(index);
                return;
            }
        }
    }

    fn liveNodeCountForMount(self: *const Scene, id: MountHandle) usize {
        const mount_slot = self.lookupMount(id) orelse return 0;
        var count: usize = 0;
        for (mount_slot.owned_nodes.items) |handle| {
            if (self.lookupNode(handle) != null) count += 1;
        }
        return count;
    }
};

pub const MountContext = struct {
    scene: *Scene,
    id: MountHandle,

    pub fn isAlive(self: *const MountContext) bool {
        return self.scene.lookupMount(self.id) != null;
    }

    pub fn deinit(self: *MountContext) void {
        self.scene.destroyMount(self.id);
    }

    pub fn child(self: *MountContext, anchor: ?NodeHandle) !MountContext {
        _ = try self.scene.liveMount(self.id);
        if (anchor) |handle| {
            const node = self.scene.lookupNode(handle) orelse return error.StaleNode;
            if (!self.scene.isAncestorOrSelf(node.owner, self.id)) return error.InvalidParent;
        }

        const child_id = try self.scene.allocateMount(self.id, anchor);
        errdefer self.scene.releaseMountSlot(child_id);
        const mount = try self.scene.liveMount(self.id);
        try mount.children.append(self.scene.allocator, child_id);
        return .{ .scene = self.scene, .id = child_id };
    }

    pub fn create(self: *MountContext, kind: NodeKind, parent: ?NodeHandle) !NodeHandle {
        const mount = try self.scene.liveMount(self.id);
        const actual_parent = parent orelse mount.anchor;
        if (actual_parent) |parent_handle| {
            const parent_node = self.scene.lookupNode(parent_handle) orelse return error.StaleNode;
            if (!self.scene.isAncestorOrSelf(parent_node.owner, self.id)) return error.InvalidParent;
        } else if (mount.parent != null and mount.anchor != null) {
            return error.InvalidParent;
        }

        const handle = try self.scene.allocateNode(.{
            .kind = kind,
            .owner = self.id,
        });
        errdefer self.scene.releaseNodeSlot(handle);
        try mount.owned_nodes.append(self.scene.allocator, handle);
        try self.scene.attachNode(handle, actual_parent);
        const stored = self.scene.lookupNodeMut(handle) orelse unreachable;
        stored.dirty = .{ .layout = true, .paint = true };
        if (actual_parent) |parent_handle| self.scene.markLayoutAncestors(parent_handle);
        return handle;
    }

    pub fn spacer(self: *MountContext, parent: ?NodeHandle, flex: u32) !NodeHandle {
        const handle = try self.create(.spacer, parent);
        const node = self.scene.lookupNodeMut(handle) orelse unreachable;
        node.properties.flex = flex;
        return handle;
    }

    pub fn shape(self: *MountContext, parent: ?NodeHandle, fill: Color) !NodeHandle {
        if (!properties.validColor(fill)) return error.InvalidValue;
        const handle = try self.create(.shape, parent);
        const node = self.scene.lookupNodeMut(handle) orelse unreachable;
        node.properties.fill = fill;
        return handle;
    }

    pub fn text(self: *MountContext, parent: ?NodeHandle, value: []const u8) !NodeHandle {
        const handle = try self.create(.text, parent);
        errdefer self.remove(handle) catch unreachable;
        const copy = try self.scene.allocator.dupe(u8, value);
        const node = self.scene.lookupNodeMut(handle) orelse unreachable;
        node.properties.text = copy;
        return handle;
    }

    pub fn remove(self: *MountContext, handle: NodeHandle) NodeError!void {
        const mount = try self.scene.liveMount(self.id);
        const node = self.scene.lookupNode(handle) orelse return error.StaleNode;
        if (!node.owner.eql(self.id)) return error.InvalidParent;
        _ = mount;
        self.scene.destroyNode(handle);
    }

    pub fn ownedNodeCount(self: *const MountContext) usize {
        return self.scene.liveNodeCountForMount(self.id);
    }
};

fn isDirty(flags: DirtyFlags) bool {
    return flags.layout or flags.paint;
}

fn freeSnapshotText(allocator: Allocator, snapshot: NodeSnapshot) void {
    if (snapshot.properties.text.len != 0) allocator.free(snapshot.properties.text);
}

test "mounts retain the six native node kinds and preserve parent order" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();

    const root = try mount.create(.row, null);
    const first = try mount.text(root, "first");
    const second = try mount.shape(root, Color.rgba(1, 0, 0, 1));
    const third = try mount.spacer(root, 3);
    const stack = try mount.create(.stack, root);
    const column = try mount.create(.column, stack);
    _ = try mount.create(.shape, column);

    try std.testing.expectEqual(@as(usize, 7), scene.liveNodeCount());
    try std.testing.expectEqual(NodeKind.text, scene.node(first).?.kind);
    try std.testing.expectEqual(NodeKind.shape, scene.node(second).?.kind);
    try std.testing.expectEqual(@as(u32, 3), scene.node(third).?.properties.flex);
    try std.testing.expectEqual(NodeKind.column, scene.node(column).?.kind);
}

test "context destruction recursively invalidates descendants and stale handles" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    var parent = try scene.mount();
    const root = try parent.create(.row, null);
    var child = try parent.child(root);
    const child_root = try child.create(.column, null);
    var grandchild = try child.child(child_root);
    const leaf = try grandchild.text(null, "owned by grandchild");

    try std.testing.expectEqual(@as(usize, 3), scene.liveMountCount());
    try std.testing.expectEqual(@as(usize, 3), scene.liveNodeCount());
    child.deinit();

    try std.testing.expect(!child.isAlive());
    try std.testing.expect(!grandchild.isAlive());
    try std.testing.expect(scene.node(child_root) == null);
    try std.testing.expect(scene.node(leaf) == null);
    try std.testing.expectEqual(@as(usize, 1), scene.liveMountCount());
    try std.testing.expectEqual(@as(usize, 1), scene.liveNodeCount());

    parent.deinit();
    try std.testing.expect(scene.node(root) == null);
    try std.testing.expectEqual(@as(usize, 0), scene.liveNodeCount());
}

test "destroying a node detaches its subtree without invalidating siblings" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const root = try mount.create(.row, null);
    const remove = try mount.create(.column, root);
    const leaf = try mount.text(remove, "gone");
    const keep = try mount.text(root, "kept");

    try mount.remove(remove);
    try std.testing.expect(scene.node(remove) == null);
    try std.testing.expect(scene.node(leaf) == null);
    try std.testing.expect(scene.node(keep) != null);
    try std.testing.expectEqual(@as(?NodeHandle, root), scene.node(keep).?.parent);
}

test "children expose stable retained order for roots and descendants" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const first_root = try mount.create(.row, null);
    const second_root = try mount.create(.column, null);
    const first_child = try mount.text(first_root, "one");
    const second_child = try mount.text(first_root, "two");

    const roots = try scene.childrenAlloc(std.testing.allocator, null);
    defer std.testing.allocator.free(roots);
    try std.testing.expectEqualSlices(NodeHandle, &.{ first_root, second_root }, roots);

    const children = try scene.childrenAlloc(std.testing.allocator, first_root);
    defer std.testing.allocator.free(children);
    try std.testing.expectEqualSlices(NodeHandle, &.{ first_child, second_child }, children);

    try mount.remove(first_root);
    const remaining_roots = try scene.childrenAlloc(std.testing.allocator, null);
    defer std.testing.allocator.free(remaining_roots);
    try std.testing.expectEqualSlices(NodeHandle, &.{second_root}, remaining_roots);
}

test "removing an anchor recursively disposes its child mount" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    var parent = try scene.mount();
    defer parent.deinit();
    const anchor = try parent.create(.row, null);
    var child = try parent.child(anchor);
    const child_node = try child.text(null, "child");

    try parent.remove(anchor);
    try std.testing.expect(!child.isAlive());
    try std.testing.expect(scene.node(anchor) == null);
    try std.testing.expect(scene.node(child_node) == null);
    try std.testing.expectEqual(@as(usize, 0), scene.liveNodeCount());
    try std.testing.expectEqual(@as(usize, 1), scene.liveMountCount());
}

test "node generations prevent an old handle from addressing a recycled slot" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    var mount = try scene.mount();
    defer mount.deinit();
    const old = try mount.create(.row, null);
    try mount.remove(old);
    const fresh = try mount.create(.column, null);

    try std.testing.expectEqual(old.slot, fresh.slot);
    try std.testing.expect(old.generation != fresh.generation);
    try std.testing.expectError(error.StaleNode, scene.dirtyFlags(old));
    try std.testing.expect(scene.node(fresh) != null);
}
