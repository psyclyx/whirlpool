//! Tree ownership, structural mutation, and focus repair for a WM World.

const std = @import("std");
const ids = @import("../ids.zig");
const types = @import("../types.zig");

const WindowId = ids.WindowId;
const OutputId = ids.OutputId;
const TagId = ids.TagId;
const ColumnId = ids.ColumnId;
const NodeId = ids.NodeId;
const Window = types.Window;
const Node = types.Node;
const Child = types.Child;
const ColumnSpec = types.ColumnSpec;
const Axis = types.Axis;
const ContainerMode = types.ContainerMode;
const Direction = types.Direction;

pub fn insertWindowInPlace(world: anytype, window_id: WindowId, column_id: ColumnId) !void {
    const window = world.windows.getConst(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle != .announced) return error.InvalidLifecycle;
    const column = world.columns.getConst(column_id) orelse return error.UnknownColumn;
    if (column.tag != window.tag) return error.TagMismatch;
    if (window.output) |output_id| if (world.outputs.getConst(output_id) == null) return error.UnknownOutput;
    try world.window_index.ensureUnusedCapacity(1);
    const node_id = try world.nodes.insert(.{
        .id = undefined,
        .column = column_id,
        .window = window_id,
    });
    errdefer world.nodes.discard(node_id) catch {};
    try attachNodeInPlace(world, node_id, column_id);
    world.window_index.putAssumeCapacity(window_id, node_id);
    world.windows.get(window_id).?.lifecycle = .managed;
}

pub fn destroyWindowInPlace(world: anytype, window_id: WindowId) !void {
    const window = world.windows.getConst(window_id) orelse return error.UnknownWindow;
    const tag_id = window.tag;
    if (world.window_index.get(window_id)) |node_id| {
        try detachNodeInPlace(world, node_id);
        try world.nodes.discard(node_id);
        _ = world.window_index.remove(window_id);
    }
    try world.windows.discard(window_id);
    repairFocus(world, tag_id);
}

pub fn focusWindowInPlace(world: anytype, window_id: WindowId) !void {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle != .managed) return error.NotFocusable;
    const output_id = window.output orelse return error.NotVisible;
    const output = world.outputs.getConst(output_id) orelse return error.UnknownOutput;
    if (output.active_tag != window.tag) return error.NotVisible;
    const node_id = world.window_index.get(window_id) orelse return error.NotFocusable;
    const tag = world.tags.get(window.tag) orelse return error.UnknownTag;
    tag.focused = node_id;
    window.focus_serial = world.next_focus_serial;
    world.next_focus_serial +|= 1;
}

pub fn focusDirectionInPlace(world: anytype, output: OutputId, direction: Direction) !void {
    const focused = focusedNode(world, output) orelse return error.NoFocusTarget;
    const focused_node = world.nodes.getConst(focused) orelse return error.InvalidInvariant;
    const column = world.columns.getConst(focused_node.column) orelse return error.InvalidInvariant;
    const tag_id = column.tag;
    const tag = world.tags.getConst(tag_id) orelse return error.InvalidInvariant;

    var leaves = std.ArrayList(NodeId).empty;
    defer leaves.deinit(world.allocator);
    try collectVisibleLeaves(world, column.root, &leaves);
    const current_index = indexOfNode(leaves.items, focused) orelse return error.NoFocusTarget;
    var target: ?NodeId = null;
    switch (direction) {
        .up => {
            if (current_index != 0) target = leaves.items[current_index - 1];
        },
        .down => {
            if (current_index + 1 < leaves.items.len) target = leaves.items[current_index + 1];
        },
        .left, .right => {
            const column_index = indexOfColumn(tag.columns.items, column.id) orelse return error.InvalidInvariant;
            const target_index = if (direction == .left)
                if (column_index == 0) null else column_index - 1
            else if (column_index + 1 >= tag.columns.items.len) null else column_index + 1;
            if (target_index) |index| {
                const target_column = world.columns.getConst(tag.columns.items[index]) orelse return error.InvalidInvariant;
                var target_leaves = std.ArrayList(NodeId).empty;
                defer target_leaves.deinit(world.allocator);
                try collectVisibleLeaves(world, target_column.root, &target_leaves);
                if (target_leaves.items.len != 0) {
                    target = if (direction == .left)
                        target_leaves.items[target_leaves.items.len - 1]
                    else
                        target_leaves.items[0];
                }
            }
        },
    }
    const target_id = target orelse return error.NoFocusTarget;
    const target_window = world.nodes.getConst(target_id).?.window orelse return error.InvalidInvariant;
    try focusWindowInPlace(world, target_window);
}

pub fn swapDirectionInPlace(world: anytype, output: OutputId, direction: Direction) !void {
    const focused = focusedNode(world, output) orelse return error.NoFocusTarget;
    const before = world.window_index.count();
    try focusDirectionInPlace(world, output, direction);
    const target = focusedNode(world, output) orelse return error.InvalidInvariant;
    try swapNodesInPlace(world, focused, target);
    // Keep the originally focused physical node selected. This makes a
    // swap a spatial operation rather than a surprise focus transition.
    const focused_window = world.nodes.getConst(focused).?.window orelse return error.InvalidInvariant;
    try focusWindowInPlace(world, focused_window);
    std.debug.assert(before == world.window_index.count());
}

pub fn absorbInPlace(world: anytype, output: OutputId, direction: Direction) !void {
    const focused = focusedNode(world, output) orelse return error.NoFocusTarget;
    const node = world.nodes.getConst(focused) orelse return error.InvalidInvariant;
    const column = world.columns.getConst(node.column) orelse return error.InvalidInvariant;
    if (direction == .up or direction == .down) {
        var leaves = std.ArrayList(NodeId).empty;
        defer leaves.deinit(world.allocator);
        try collectVisibleLeaves(world, column.root, &leaves);
        const current_index = indexOfNode(leaves.items, focused) orelse return error.NoFocusTarget;
        const target_index = if (direction == .up)
            if (current_index == 0) null else current_index - 1
        else if (current_index + 1 >= leaves.items.len) null else current_index + 1;
        const target = leaves.items[target_index orelse return error.NoFocusTarget];
        const moved_window = world.nodes.getConst(target).?.window orelse return error.InvalidInvariant;

        try detachNodeInPlace(world, target);
        const container_id = try wrapNodeInPlace(world, focused, .split, .vertical);
        const container = world.nodes.get(container_id) orelse return error.InvalidInvariant;
        try container.children.ensureTotalCapacity(world.allocator, 2);
        if (direction == .up) {
            container.children.appendAssumeCapacity(container.children.items[0]);
            container.children.items[0] = .{ .id = target };
            container.active_child = 1;
        } else {
            container.children.appendAssumeCapacity(.{ .id = target });
            container.active_child = 0;
        }
        world.nodes.get(target).?.parent = container_id;
        setColumnRecursive(world, target, column.id);
        try focusWindowInPlace(world, moved_window);
        return;
    }
    const tag = world.tags.getConst(column.tag) orelse return error.InvalidInvariant;
    const index = indexOfColumn(tag.columns.items, column.id) orelse return error.InvalidInvariant;
    const target_index = if (direction == .left)
        if (index == 0) null else index - 1
    else if (index + 1 >= tag.columns.items.len) null else index + 1;
    const destination_index = target_index orelse return error.NoFocusTarget;
    const source_column = world.columns.get(tag.columns.items[destination_index]) orelse return error.InvalidInvariant;
    var leaves = std.ArrayList(NodeId).empty;
    defer leaves.deinit(world.allocator);
    try collectVisibleLeaves(world, source_column.root, &leaves);
    const source = if (direction == .left)
        if (leaves.items.len == 0) null else leaves.items[leaves.items.len - 1]
    else if (leaves.items.len == 0) null else leaves.items[0];
    const source_id = source orelse return error.NoFocusTarget;
    try moveNodeInPlace(world, source_id, column.id);
    const moved_window = world.nodes.getConst(source_id).?.window orelse return error.InvalidInvariant;
    try focusWindowInPlace(world, moved_window);
}

pub fn ejectInPlace(world: anytype, node_id: NodeId) !void {
    const node = world.nodes.getConst(node_id) orelse return error.UnknownNode;
    if (!node.isLeaf()) return error.NotLeaf;
    const column_id = node.column;
    if (node.parent == null) return error.NoOp;
    try moveNodeInPlace(world, node_id, column_id);
}

pub fn expelInPlace(world: anytype, node_id: NodeId, direction: Direction) !void {
    if (direction != .left and direction != .right) return error.NoFocusTarget;
    const node = world.nodes.getConst(node_id) orelse return error.UnknownNode;
    const column = world.columns.getConst(node.column) orelse return error.InvalidInvariant;
    const tag = column.tag;
    const current_index = indexOfColumn(world.tags.getConst(tag).?.columns.items, column.id) orelse return error.InvalidInvariant;
    const new_index = if (direction == .left) current_index else current_index + 1;
    const new_column = try createColumnAt(world, tag, new_index, .{ .width = column.width }, true);
    try moveNodeInPlace(world, node_id, new_column);
    if (world.nodes.getConst(node_id).?.window) |window_id| try focusWindowInPlace(world, window_id);
}

pub fn moveNodeInPlace(world: anytype, node_id: NodeId, column_id: ColumnId) !void {
    const node = world.nodes.getConst(node_id) orelse return error.UnknownNode;
    const destination = world.columns.getConst(column_id) orelse return error.UnknownColumn;
    const source_column = world.columns.getConst(node.column) orelse return error.InvalidInvariant;
    const source_tag = source_column.tag;
    const destination_tag = destination.tag;
    if (node.column == column_id and node.parent == null) return error.NoOp;
    try detachNodeInPlace(world, node_id);
    setColumnRecursive(world, node_id, column_id);
    try attachNodeInPlace(world, node_id, column_id);
    repairFocus(world, source_tag);
    repairFocus(world, destination_tag);
}

pub fn swapNodesInPlace(world: anytype, first_id: NodeId, second_id: NodeId) !void {
    if (first_id == second_id) return error.NoOp;
    const first = world.nodes.get(first_id) orelse return error.UnknownNode;
    const second = world.nodes.get(second_id) orelse return error.UnknownNode;
    if (!first.isLeaf() or !second.isLeaf()) return error.NotLeaf;
    const first_window = first.window orelse return error.InvalidInvariant;
    const second_window = second.window orelse return error.InvalidInvariant;
    const first_column = world.columns.getConst(first.column) orelse return error.InvalidInvariant;
    const second_column = world.columns.getConst(second.column) orelse return error.InvalidInvariant;
    first.window = second_window;
    second.window = first_window;
    if (first_column.tag != second_column.tag) {
        world.windows.get(first_window).?.tag = second_column.tag;
        world.windows.get(second_window).?.tag = first_column.tag;
        repairFocus(world, first_column.tag);
        repairFocus(world, second_column.tag);
    }
    world.window_index.put(first_window, second_id) catch return error.InvalidInvariant;
    world.window_index.put(second_window, first_id) catch return error.InvalidInvariant;
}

pub fn wrapNodeInPlace(world: anytype, node_id: NodeId, mode: ContainerMode, axis: Axis) !NodeId {
    const node = world.nodes.getConst(node_id) orelse return error.UnknownNode;
    const column_id = node.column;
    const old_parent = node.parent;
    const container_id = try world.nodes.insert(.{
        .id = undefined,
        .column = column_id,
        .mode = mode,
        .axis = axis,
        .active_child = 0,
    });
    errdefer world.nodes.discard(container_id) catch {};
    const container = world.nodes.get(container_id).?;
    try container.children.ensureTotalCapacity(world.allocator, 1);
    if (old_parent) |parent_id| {
        try replaceChild(world, parent_id, node_id, container_id);
    } else {
        const column = world.columns.get(column_id) orelse return error.InvalidInvariant;
        if (column.root != node_id) return error.InvalidInvariant;
        column.root = container_id;
    }
    container.children.appendAssumeCapacity(.{ .id = node_id });
    world.nodes.get(node_id).?.parent = container_id;
    return container_id;
}

pub fn unwrapNodeInPlace(world: anytype, node_id: NodeId) !void {
    const node = world.nodes.get(node_id) orelse return error.UnknownNode;
    if (node.isLeaf()) return error.NotContainer;
    if (node.children.items.len == 0) return error.InvalidInvariant;
    const parent_id = node.parent;
    if (parent_id == null and node.children.items.len != 1) return error.CannotUnwrap;
    if (parent_id == null) {
        const child_id = node.children.items[0].id;
        const column = world.columns.get(node.column) orelse return error.InvalidInvariant;
        column.root = child_id;
        world.nodes.get(child_id).?.parent = null;
        node.children.clearRetainingCapacity();
        try world.nodes.discard(node_id);
        return;
    }

    const parent = world.nodes.get(parent_id.?) orelse return error.InvalidInvariant;
    const index = childIndex(parent, node_id) orelse return error.InvalidInvariant;
    const child_count = node.children.items.len;
    try parent.children.ensureTotalCapacity(world.allocator, parent.children.items.len + child_count - 1);
    const old_len = parent.children.items.len;
    parent.children.items.len = old_len + child_count - 1;
    std.mem.copyBackwards(
        Child,
        parent.children.items[index + child_count .. old_len + child_count - 1],
        parent.children.items[index + 1 .. old_len],
    );
    for (node.children.items, 0..) |child, offset| {
        parent.children.items[index + offset] = child;
        world.nodes.get(child.id).?.parent = parent_id;
    }
    node.children.clearRetainingCapacity();
    try world.nodes.discard(node_id);
    repairActiveChild(parent);
}

pub fn setContainerModeInPlace(world: anytype, node_id: NodeId, mode: ContainerMode, axis: Axis) !void {
    const node = world.nodes.get(node_id) orelse return error.UnknownNode;
    if (node.isLeaf()) return error.NotContainer;
    if (node.children.items.len < 2) return error.InvalidInvariant;
    node.mode = mode;
    node.axis = axis;
    repairActiveChild(node);
}

pub fn setActiveTabInPlace(world: anytype, container_id: NodeId, child_id: NodeId) !void {
    const container = world.nodes.get(container_id) orelse return error.UnknownNode;
    if (container.mode != .tabbed) return error.NotTabbed;
    const index = childIndex(container, child_id) orelse return error.NotAChild;
    container.active_child = index;
    const column_tag = world.columns.get(container.column).?.tag;
    repairFocus(world, column_tag);
}

pub fn attachNodeInPlace(world: anytype, node_id: NodeId, column_id: ColumnId) !void {
    const column = world.columns.get(column_id) orelse return error.UnknownColumn;
    const node = world.nodes.get(node_id) orelse return error.UnknownNode;
    if (node.parent != null) return error.NodeAlreadyAttached;
    if (column.root == null) {
        column.root = node_id;
        node.column = column_id;
        return;
    }

    const root_id = column.root.?;
    const root = world.nodes.get(root_id) orelse return error.InvalidInvariant;
    if (root.mode) |mode| {
        _ = mode;
        try root.children.ensureTotalCapacity(world.allocator, root.children.items.len + 1);
        root.children.appendAssumeCapacity(.{ .id = node_id });
        node.parent = root_id;
        node.column = column_id;
        return;
    }

    const parent_id = try world.nodes.insert(.{
        .id = undefined,
        .column = column_id,
        .mode = .split,
        .axis = .horizontal,
    });
    errdefer world.nodes.discard(parent_id) catch {};
    const parent = world.nodes.get(parent_id).?;
    try parent.children.ensureTotalCapacity(world.allocator, 2);
    parent.children.appendAssumeCapacity(.{ .id = root_id });
    parent.children.appendAssumeCapacity(.{ .id = node_id });
    parent.active_child = 0;
    world.columns.get(column_id).?.root = parent_id;
    world.nodes.get(root_id).?.parent = parent_id;
    world.nodes.get(node_id).?.parent = parent_id;
    world.nodes.get(node_id).?.column = column_id;
}

pub fn detachNodeInPlace(world: anytype, node_id: NodeId) !void {
    const node = world.nodes.get(node_id) orelse return error.UnknownNode;
    if (node.parent) |parent_id| {
        const parent = world.nodes.get(parent_id) orelse return error.InvalidInvariant;
        _ = parent.children.orderedRemove(childIndex(parent, node_id) orelse return error.InvalidInvariant);
        node.parent = null;
        try normalizeAfterDetach(world, parent_id);
    } else {
        const column = world.columns.get(node.column) orelse return error.InvalidInvariant;
        if (column.root != node_id) return error.InvalidInvariant;
        column.root = null;
    }
}

pub fn normalizeAfterDetach(world: anytype, container_id: NodeId) !void {
    const container = world.nodes.get(container_id) orelse return error.InvalidInvariant;
    if (container.children.items.len >= 2) {
        repairActiveChild(container);
        return;
    }
    const parent_id = container.parent;
    if (container.children.items.len == 1) {
        const child_id = container.children.items[0].id;
        const column_id = container.column;
        container.children.clearRetainingCapacity();
        world.nodes.get(child_id).?.parent = parent_id;
        if (parent_id) |parent_value| {
            try replaceChild(world, parent_value, container_id, child_id);
        } else {
            world.columns.get(column_id).?.root = child_id;
        }
        try world.nodes.discard(container_id);
        if (parent_id) |parent_value| repairActiveChild(world.nodes.get(parent_value).?);
        return;
    }

    const column_id = container.column;
    if (parent_id) |parent_value| {
        const parent = world.nodes.get(parent_value) orelse return error.InvalidInvariant;
        _ = parent.children.orderedRemove(childIndex(parent, container_id) orelse return error.InvalidInvariant);
        try world.nodes.discard(container_id);
        try normalizeAfterDetach(world, parent_value);
    } else {
        world.columns.get(column_id).?.root = null;
        try world.nodes.discard(container_id);
    }
}

pub fn setColumnRecursive(world: anytype, node_id: NodeId, column_id: ColumnId) void {
    const node = world.nodes.get(node_id).?;
    node.column = column_id;
    for (node.children.items) |child| setColumnRecursive(world, child.id, column_id);
    if (node.window) |window_id| world.windows.get(window_id).?.tag = world.columns.get(column_id).?.tag;
}

pub fn replaceChild(world: anytype, parent_id: NodeId, old_id: NodeId, new_id: NodeId) !void {
    const parent = world.nodes.get(parent_id) orelse return error.InvalidInvariant;
    const index = childIndex(parent, old_id) orelse return error.InvalidInvariant;
    parent.children.items[index].id = new_id;
}

pub fn createColumnAt(world: anytype, tag_id: TagId, index: usize, spec: ColumnSpec, insert: bool) !ColumnId {
    const tag = world.tags.get(tag_id) orelse return error.UnknownTag;
    if (!types.isFinitePositive(spec.width) or spec.width < 0.05 or spec.width > 4) return error.InvalidWidth;
    if (index > tag.columns.items.len) return error.InvalidColumnPosition;
    try tag.columns.ensureTotalCapacity(world.allocator, tag.columns.items.len + 1);
    const id = try world.columns.insert(.{ .id = undefined, .tag = tag_id, .width = spec.width });
    errdefer world.columns.discard(id) catch {};
    if (insert) {
        const old_len = tag.columns.items.len;
        tag.columns.items.len = old_len + 1;
        std.mem.copyBackwards(ColumnId, tag.columns.items[index + 1 ..], tag.columns.items[index..old_len]);
        tag.columns.items[index] = id;
    } else {
        tag.columns.appendAssumeCapacity(id);
    }
    return id;
}

pub fn tagColumnCount(world: anytype, tag_id: TagId) ?usize {
    return if (world.tags.getConst(tag_id)) |tag| tag.columns.items.len else null;
}

pub fn focusedNode(world: anytype, output_id: OutputId) ?NodeId {
    const output = world.outputs.getConst(output_id) orelse return null;
    const tag = world.tags.getConst(output.active_tag) orelse return null;
    const node_id = tag.focused orelse return null;
    const node = world.nodes.getConst(node_id) orelse return null;
    const window_id = node.window orelse return null;
    return if (isVisible(world, window_id) and world.windows.getConst(window_id).?.output == output_id) node_id else null;
}

pub fn collectVisibleLeaves(world: anytype, maybe_node: ?NodeId, output: *std.ArrayList(NodeId)) !void {
    const node_id = maybe_node orelse return;
    const node = world.nodes.getConst(node_id) orelse return error.InvalidInvariant;
    if (node.isLeaf()) {
        const window_id = node.window orelse return error.InvalidInvariant;
        if (isVisible(world, window_id)) try output.append(world.allocator, node_id);
        return;
    }
    if (node.mode == .tabbed) {
        if (node.active_child >= node.children.items.len) return error.InvalidInvariant;
        return collectVisibleLeaves(world, node.children.items[node.active_child].id, output);
    }
    for (node.children.items) |child| try collectVisibleLeaves(world, child.id, output);
}

pub fn isVisible(world: anytype, window_id: WindowId) bool {
    const window = world.windows.getConst(window_id) orelse return false;
    if (window.lifecycle != .managed or window.placement == .scratchpad) return false;
    const output_id = window.output orelse return false;
    const output = world.outputs.getConst(output_id) orelse return false;
    return output.active_tag == window.tag and world.window_index.get(window_id) != null;
}

pub fn repairFocus(world: anytype, tag_id: TagId) void {
    const tag = world.tags.get(tag_id) orelse return;
    if (tag.focused) |focused| {
        if (world.nodes.getConst(focused)) |node| if (node.window) |window_id| {
            if (isVisible(world, window_id)) return;
        };
    }
    var best: ?WindowId = null;
    var best_serial: u64 = 0;
    for (world.windows.slots.items) |slot| {
        const window = slot.value orelse continue;
        if (window.tag != tag_id or !isVisible(world, window.id)) continue;
        if (best == null or window.focus_serial >= best_serial) {
            best = window.id;
            best_serial = window.focus_serial;
        }
    }
    tag.focused = if (best) |window_id| world.window_index.get(window_id) else null;
}

fn childIndex(node: *const Node, child_id: NodeId) ?usize {
    for (node.children.items, 0..) |child, index| if (child.id == child_id) return index;
    return null;
}

fn indexOfNode(nodes: []const NodeId, wanted: NodeId) ?usize {
    for (nodes, 0..) |node_id, index| if (node_id == wanted) return index;
    return null;
}

fn indexOfColumn(columns: []const ColumnId, wanted: ColumnId) ?usize {
    for (columns, 0..) |column_id, index| if (column_id == wanted) return index;
    return null;
}

fn repairActiveChild(node: *Node) void {
    if (node.mode == .tabbed and node.active_child >= node.children.items.len) node.active_child = node.children.items.len - 1;
}
