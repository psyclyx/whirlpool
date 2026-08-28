//! Whole-world invariants and validation for the authoritative WM state.

const std = @import("std");
const ids = @import("../ids.zig");
const types = @import("../types.zig");

const NodeId = ids.NodeId;
const WindowId = ids.WindowId;
const Rect = types.Rect;
const OutputConfig = types.OutputConfig;

pub fn validate(world: anytype) !void {
    try validateOutputs(world);
    try validateTagsAndColumns(world);
    try validateNodes(world);
    try validateWindows(world);
}

fn validateOutputs(world: anytype) !void {
    for (world.outputs.slots.items) |slot| {
        const output = slot.value orelse continue;
        if (world.tags.getConst(output.active_tag) == null) return error.InvalidInvariant;
        if (output.previous_tag) |tag| if (world.tags.getConst(tag) == null) return error.InvalidInvariant;
        try validateRectPair(output.bounds, output.usable);
        if (output.usable.width == 0 or output.usable.height == 0) return error.InvalidInvariant;
        try validateOutputConfig(output.configuration);
    }
}

fn validateTagsAndColumns(world: anytype) !void {
    for (world.tags.slots.items) |slot| {
        const tag = slot.value orelse continue;
        try validateOptionalName(tag.name);
        if (!std.math.isFinite(tag.camera.current) or !std.math.isFinite(tag.camera.target)) return error.InvalidInvariant;
        if (tag.camera.target < 0) return error.InvalidInvariant;
        for (tag.columns.items, 0..) |column_id, index| {
            if (indexOfColumn(tag.columns.items[0..index], column_id) != null) return error.InvalidInvariant;
            const column = world.columns.getConst(column_id) orelse return error.InvalidInvariant;
            if (column.tag != tag.id or !types.isFinitePositive(column.width) or column.width < 0.05 or column.width > 4) return error.InvalidInvariant;
        }
    }
    for (world.columns.slots.items) |slot| {
        const column = slot.value orelse continue;
        const tag = world.tags.getConst(column.tag) orelse return error.InvalidInvariant;
        if (indexOfColumn(tag.columns.items, column.id) == null) return error.InvalidInvariant;
        if (column.root) |root_id| {
            const root = world.nodes.getConst(root_id) orelse return error.InvalidInvariant;
            if (root.parent != null or root.column != column.id) return error.InvalidInvariant;
        }
    }
}

fn validateNodes(world: anytype) !void {
    var leaf_count: usize = 0;
    for (world.nodes.slots.items, 0..) |slot, index| {
        const node = slot.value orelse continue;
        const expected = NodeId.fromParts(@intCast(index), slot.generation);
        if (node.id != expected or world.columns.getConst(node.column) == null) return error.InvalidInvariant;
        if (node.parent) |parent_id| {
            const parent = world.nodes.getConst(parent_id) orelse return error.InvalidInvariant;
            if (childIndex(parent, node.id) == null or parent.column != node.column) return error.InvalidInvariant;
        } else {
            const column = world.columns.getConst(node.column) orelse return error.InvalidInvariant;
            if (column.root != node.id) return error.InvalidInvariant;
        }
        var ancestor = node.parent;
        var hops: usize = 0;
        while (ancestor) |ancestor_id| {
            hops += 1;
            if (hops > world.nodes.liveCount()) return error.InvalidInvariant;
            ancestor = world.nodes.getConst(ancestor_id).?.parent;
        }

        if (node.isLeaf()) {
            leaf_count += 1;
            const window_id = node.window orelse return error.InvalidInvariant;
            if (world.windows.getConst(window_id) == null or world.window_index.get(window_id) != node.id) return error.InvalidInvariant;
            if (node.children.items.len != 0) return error.InvalidInvariant;
        } else {
            if (node.window != null or node.children.items.len == 0) return error.InvalidInvariant;
            if (node.mode == .tabbed and node.active_child >= node.children.items.len) return error.InvalidInvariant;
            var weight_sum: f32 = 0;
            for (node.children.items, 0..) |child, child_index| {
                if (child.id == node.id or childIndexOfLater(node.children.items[0..child_index], child.id)) return error.InvalidInvariant;
                if (!types.isFinitePositive(child.weight)) return error.InvalidInvariant;
                weight_sum += child.weight;
                const child_node = world.nodes.getConst(child.id) orelse return error.InvalidInvariant;
                if (child_node.parent != node.id) return error.InvalidInvariant;
            }
            if (!std.math.isFinite(weight_sum) or weight_sum <= 0) return error.InvalidInvariant;
        }
    }
    if (leaf_count != world.window_index.count()) return error.InvalidInvariant;
    var iterator = world.window_index.iterator();
    while (iterator.next()) |entry| {
        const window = world.windows.getConst(entry.key_ptr.*) orelse return error.InvalidInvariant;
        const node = world.nodes.getConst(entry.value_ptr.*) orelse return error.InvalidInvariant;
        if (node.window != window.id or !node.isLeaf()) return error.InvalidInvariant;
    }
}

fn validateWindows(world: anytype) !void {
    var marks = std.StringHashMap(WindowId).init(world.allocator);
    defer marks.deinit();
    for (world.windows.slots.items) |slot| {
        const window = slot.value orelse continue;
        if (world.tags.getConst(window.tag) == null) return error.InvalidInvariant;
        if (window.output) |output_id| if (world.outputs.getConst(output_id) == null) return error.InvalidInvariant;
        try validateFloatingGeometry(window.floating_geometry);
        for (window.marks.items) |mark| {
            try validateName(mark.name);
            if (marks.fetchPut(mark.name, window.id) catch return error.InvalidInvariant) |_| return error.InvalidInvariant;
        }
        switch (window.lifecycle) {
            .announced => if (world.window_index.get(window.id) != null) return error.InvalidInvariant,
            .managed, .closing => if (world.window_index.get(window.id) == null) return error.InvalidInvariant,
        }
    }
    for (world.tags.slots.items) |slot| {
        const tag = slot.value orelse continue;
        if (tag.focused) |node_id| {
            const node = world.nodes.getConst(node_id) orelse return error.InvalidInvariant;
            const window_id = node.window orelse return error.InvalidInvariant;
            if (world.windows.getConst(window_id) == null or !isVisible(world, window_id)) return error.InvalidInvariant;
        }
    }
}

fn isVisible(world: anytype, window_id: WindowId) bool {
    const window = world.windows.getConst(window_id) orelse return false;
    if (window.lifecycle != .managed or window.placement == .scratchpad) return false;
    const output_id = window.output orelse return false;
    const output = world.outputs.getConst(output_id) orelse return false;
    return output.active_tag == window.tag;
}

fn childIndex(node: *const types.Node, child_id: NodeId) ?usize {
    for (node.children.items, 0..) |child, index| if (child.id == child_id) return index;
    return null;
}

fn childIndexOfLater(children: []const types.Child, child_id: NodeId) bool {
    for (children) |child| if (child.id == child_id) return true;
    return false;
}

fn indexOfColumn(columns: []const ids.ColumnId, wanted: ids.ColumnId) ?usize {
    for (columns, 0..) |column_id, index| if (column_id == wanted) return index;
    return null;
}

pub fn validateRectPair(bounds: Rect, usable: Rect) !void {
    if (usable.x < bounds.x or usable.y < bounds.y or usable.right() > bounds.right() or usable.bottom() > bounds.bottom()) {
        return error.InvalidUsableRect;
    }
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    try validateOptionalName(name);
}

pub fn validateOptionalName(name: []const u8) !void {
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
}

pub fn validateOutputConfig(configuration: OutputConfig) !void {
    if (!types.isFinitePositive(configuration.scale) or configuration.scale > 16) return error.InvalidOutputConfig;
    if (configuration.mode) |mode| if (mode.width == 0 or mode.height == 0) return error.InvalidOutputConfig;
}

pub fn validateFloatingGeometry(geometry: Rect) !void {
    if (geometry.width == 0 or geometry.height == 0) return error.InvalidFloatingGeometry;
    const right = @as(i64, geometry.x) + @as(i64, geometry.width);
    const bottom = @as(i64, geometry.y) + @as(i64, geometry.height);
    if (right > std.math.maxInt(i32) or bottom > std.math.maxInt(i32)) return error.InvalidFloatingGeometry;
}
