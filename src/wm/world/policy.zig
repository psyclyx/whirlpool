//! Geometry, placement, tag, mark, output, and transfer policy mutations.

const std = @import("std");
const ids = @import("../ids.zig");
const types = @import("../types.zig");
const command = @import("../command.zig");
const validation = @import("validation.zig");
const world_tree = @import("tree.zig");

const WindowId = ids.WindowId;
const OutputId = ids.OutputId;
const TagId = ids.TagId;
const ColumnId = ids.ColumnId;
const NodeId = ids.NodeId;
const Window = types.Window;
const OutputSpec = types.OutputSpec;
const OutputConfig = types.OutputConfig;
const Rect = types.Rect;
const ResizeEdges = types.ResizeEdges;
const Point = types.Point;
const Placement = types.Placement;
const PlacementTransition = types.PlacementTransition;
const ColumnWidthStep = command.ColumnWidthStep;

pub fn resizeColumnInPlace(world: anytype, column_id: ColumnId, width: f32) !void {
    if (!types.isFinitePositive(width) or width < 0.05 or width > 4) return error.InvalidWidth;
    const column = world.columns.get(column_id) orelse return error.UnknownColumn;
    column.width = width;
}

pub fn cycleColumnWidthInPlace(world: anytype, column_id: ColumnId, step: ColumnWidthStep) !void {
    const presets = [_]f32{ 0.33, 0.5, 0.66, 1.0 };
    const column = world.columns.get(column_id) orelse return error.UnknownColumn;
    var nearest: usize = 0;
    var distance = std.math.inf(f32);
    for (presets, 0..) |preset, index| {
        const candidate_distance = @abs(preset - column.width);
        if (candidate_distance < distance) {
            distance = candidate_distance;
            nearest = index;
        }
    }
    const next = switch (step) {
        .previous => if (nearest == 0) presets.len - 1 else nearest - 1,
        .next => (nearest + 1) % presets.len,
    };
    column.width = presets[next];
}

pub fn resizeSplitInPlace(world: anytype, split_id: NodeId, child_id: NodeId, weight: f32) !void {
    if (!types.isFinitePositive(weight)) return error.InvalidWeight;
    const split = world.nodes.get(split_id) orelse return error.UnknownNode;
    if (split.mode != .split) return error.NotSplit;
    const child = childIndex(split, child_id) orelse return error.NotAChild;
    split.children.items[child].weight = weight;
}

pub fn moveFloatingInPlace(world: anytype, window_id: WindowId, delta: Point) !void {
    const window = try requireFloatingWindow(world, window_id);
    const geometry = window.floating_geometry;
    const x = checkedCoordinate(@as(i64, geometry.x) + @as(i64, delta.x)) orelse return error.InvalidFloatingGeometry;
    const y = checkedCoordinate(@as(i64, geometry.y) + @as(i64, delta.y)) orelse return error.InvalidFloatingGeometry;
    const next = Rect{ .x = x, .y = y, .width = geometry.width, .height = geometry.height };
    try validation.validateFloatingGeometry(next);
    window.floating_geometry = next;
}

pub fn resizeFloatingInPlace(world: anytype, window_id: WindowId, edges: ResizeEdges, delta: Point) !void {
    if (!edges.isValid()) return error.InvalidResizeEdges;
    const window = try requireFloatingWindow(world, window_id);
    const geometry = window.floating_geometry;
    var x: i64 = geometry.x;
    var y: i64 = geometry.y;
    var width: i64 = geometry.width;
    var height: i64 = geometry.height;

    if (edges.left) {
        x += @as(i64, delta.x);
        width -= @as(i64, delta.x);
    }
    if (edges.right) width += @as(i64, delta.x);
    if (edges.top) {
        y += @as(i64, delta.y);
        height -= @as(i64, delta.y);
    }
    if (edges.bottom) height += @as(i64, delta.y);

    const next = Rect{
        .x = std.math.cast(i32, x) orelse return error.InvalidFloatingGeometry,
        .y = std.math.cast(i32, y) orelse return error.InvalidFloatingGeometry,
        .width = std.math.cast(u32, width) orelse return error.InvalidFloatingGeometry,
        .height = std.math.cast(u32, height) orelse return error.InvalidFloatingGeometry,
    };
    try validation.validateFloatingGeometry(next);
    window.floating_geometry = next;
}

pub fn requireFloatingWindow(world: anytype, window_id: WindowId) !*Window {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle != .managed) return error.InvalidLifecycle;
    if (window.placement != .floating) return error.NotFloating;
    return window;
}

pub fn setCameraTargetInPlace(world: anytype, tag_id: TagId, target: f32) !void {
    if (!std.math.isFinite(target) or target < 0) return error.InvalidCamera;
    _ = world.tags.get(tag_id) orelse return error.UnknownTag;
    world.tags.get(tag_id).?.camera.target = target;
}

pub fn setActiveTagInPlace(world: anytype, output_id: OutputId, tag_id: TagId) !void {
    try requireTag(world, tag_id);
    const output = world.outputs.get(output_id) orelse return error.UnknownOutput;
    const previous_tag = output.active_tag;
    if (previous_tag != tag_id) {
        output.previous_tag = previous_tag;
        output.active_tag = tag_id;
        world_tree.repairFocus(world, previous_tag);
    }
    world_tree.repairFocus(world, tag_id);
}

pub fn toggleActiveTagInPlace(world: anytype, output_id: OutputId, tag_id: TagId) !void {
    const output = world.outputs.get(output_id) orelse return error.UnknownOutput;
    try requireTag(world, tag_id);
    if (output.active_tag != tag_id) return setActiveTagInPlace(world, output_id, tag_id);
    const previous = output.previous_tag orelse return error.NoPreviousTag;
    if (world.getTag(previous) == null) return error.InvalidInvariant;
    output.previous_tag = output.active_tag;
    output.active_tag = previous;
    world_tree.repairFocus(world, tag_id);
    world_tree.repairFocus(world, previous);
}

pub fn updateOutputInPlace(world: anytype, output_id: OutputId, spec: OutputSpec) !void {
    try requireTag(world, spec.active_tag);
    try validation.validateRectPair(spec.bounds, spec.usable);
    try validation.validateOutputConfig(spec.configuration);
    const output = world.outputs.get(output_id) orelse return error.UnknownOutput;
    const previous_tag = output.active_tag;
    if (previous_tag != spec.active_tag) output.previous_tag = previous_tag;
    output.active_tag = spec.active_tag;
    output.bounds = spec.bounds;
    output.usable = spec.usable;
    output.configuration = spec.configuration;
    world_tree.repairFocus(world, previous_tag);
    world_tree.repairFocus(world, spec.active_tag);
}

pub fn configureOutputInPlace(world: anytype, output_id: OutputId, configuration: OutputConfig) !void {
    try validation.validateOutputConfig(configuration);
    const output = world.outputs.get(output_id) orelse return error.UnknownOutput;
    output.configuration = configuration;
}

pub fn renameTagInPlace(world: anytype, tag_id: TagId, name: []const u8) !void {
    try validation.validateName(name);
    const tag = world.tags.get(tag_id) orelse return error.UnknownTag;
    const owned = try world.allocator.dupe(u8, name);
    world.allocator.free(tag.name);
    tag.name = owned;
}

pub fn setMarkInPlace(world: anytype, window_id: WindowId, name: []const u8) !void {
    try validation.validateName(name);
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle == .closing) return error.InvalidLifecycle;

    for (world.windows.slots.items) |*slot| {
        const other = if (slot.value) |*value| value else continue;
        for (other.marks.items, 0..) |mark, index| {
            if (!std.mem.eql(u8, mark.name, name)) continue;
            if (other.id == window_id) return;
            var removed = other.marks.orderedRemove(index);
            removed.deinit(world.allocator);
            break;
        }
    }
    for (window.marks.items) |mark| if (std.mem.eql(u8, mark.name, name)) return;
    try window.marks.append(world.allocator, .{ .name = try world.allocator.dupe(u8, name) });
}

pub fn clearMarkInPlace(world: anytype, window_id: WindowId, name: []const u8) !void {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    for (window.marks.items, 0..) |mark, index| {
        if (!std.mem.eql(u8, mark.name, name)) continue;
        var removed = window.marks.orderedRemove(index);
        removed.deinit(world.allocator);
        return;
    }
    return error.UnknownMark;
}

pub fn focusMarkInPlace(world: anytype, name: []const u8) !void {
    const window_id = windowForMark(world, name) orelse return error.UnknownMark;
    try world_tree.focusWindowInPlace(world, window_id);
}

pub fn sendWindowInPlace(world: anytype, target: command.SendTarget) !void {
    const window = world.windows.get(target.window) orelse return error.UnknownWindow;
    if (window.lifecycle != .managed) return error.InvalidLifecycle;
    try requireTag(world, target.tag);
    if (target.output) |output_id| try requireOutput(world, output_id);

    const source_tag = window.tag;
    const source_output = window.output;
    if (source_tag == target.tag and (target.output == null or target.output.? == source_output)) return error.NoOp;

    if (source_tag != target.tag) {
        const node_id = world.window_index.get(target.window) orelse return error.NotFocusable;
        const destination_column = blk: {
            const tag = world.tags.getConst(target.tag) orelse return error.UnknownTag;
            if (tag.columns.items.len != 0) break :blk tag.columns.items[0];
            break :blk try world_tree.createColumnAt(world, target.tag, 0, .{}, false);
        };
        try world_tree.detachNodeInPlace(world, node_id);
        world_tree.setColumnRecursive(world, node_id, destination_column);
        try world_tree.attachNodeInPlace(world, node_id, destination_column);
    }
    if (target.output) |output_id| window.output = output_id;
    world_tree.repairFocus(world, source_tag);
    world_tree.repairFocus(world, target.tag);
    if (source_output) |output_id| if (world.outputs.getConst(output_id)) |output| world_tree.repairFocus(world, output.active_tag);
    if (target.output) |output_id| if (world.outputs.getConst(output_id)) |output| world_tree.repairFocus(world, output.active_tag);
}

pub fn sendFocusedWindowInPlace(world: anytype, source_output: OutputId, tag_id: TagId, output_id: ?OutputId) !void {
    const node_id = world_tree.focusedNode(world, source_output) orelse return error.NoFocusTarget;
    const node = world.nodes.getConst(node_id) orelse return error.InvalidInvariant;
    const window_id = node.window orelse return error.InvalidInvariant;
    try sendWindowInPlace(world, .{ .window = window_id, .tag = tag_id, .output = output_id });
}

pub fn summonWindowInPlace(world: anytype, window_id: WindowId, output_id: OutputId) !void {
    const output = world.outputs.getConst(output_id) orelse return error.UnknownOutput;
    try sendWindowInPlace(world, .{ .window = window_id, .tag = output.active_tag, .output = output_id });
    try world_tree.focusWindowInPlace(world, window_id);
}

pub fn summonMarkInPlace(world: anytype, name: []const u8, output_id: OutputId) !void {
    const window_id = windowForMark(world, name) orelse return error.UnknownMark;
    try summonWindowInPlace(world, window_id, output_id);
}

pub fn windowForMark(world: anytype, name: []const u8) ?WindowId {
    for (world.windows.slots.items) |slot| {
        const window = slot.value orelse continue;
        for (window.marks.items) |mark| if (std.mem.eql(u8, mark.name, name)) return window.id;
    }
    return null;
}

pub fn setWindowOutputInPlace(world: anytype, window_id: WindowId, output_id: ?OutputId) !void {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (output_id) |id| try requireOutput(world, id);
    window.output = output_id;
    world_tree.repairFocus(world, window.tag);
}

pub fn setPlacementInPlace(world: anytype, window_id: WindowId, placement: Placement) !void {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle != .managed) return error.InvalidLifecycle;
    window.placement = placement;
    switch (placement) {
        .tiled => window.restore_placement = .tiled,
        .floating => window.restore_placement = .floating,
        .fullscreen, .scratchpad => {},
    }
    world_tree.repairFocus(world, window.tag);
}

pub fn transitionPlacementInPlace(world: anytype, window_id: WindowId, transition: PlacementTransition) !void {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle != .managed) return error.InvalidLifecycle;

    switch (transition) {
        .tiled => {
            window.placement = .tiled;
            window.restore_placement = .tiled;
        },
        .floating => {
            window.placement = .floating;
            window.restore_placement = .floating;
        },
        .fullscreen => {
            if (window.placement != .fullscreen) {
                window.restore_placement = switch (window.placement) {
                    .floating => .floating,
                    .tiled => .tiled,
                    .fullscreen, .scratchpad => window.restore_placement,
                };
                window.placement = .fullscreen;
            }
        },
        .scratchpad => {
            if (window.placement != .scratchpad) {
                window.restore_placement = switch (window.placement) {
                    .floating => .floating,
                    .tiled => .tiled,
                    .fullscreen, .scratchpad => window.restore_placement,
                };
                window.placement = .scratchpad;
            }
        },
        .exit_fullscreen => {
            if (window.placement != .fullscreen) return error.NotFullscreen;
            window.placement = switch (window.restore_placement) {
                .tiled => .tiled,
                .floating => .floating,
            };
        },
        .toggle_scratchpad => {
            if (window.placement == .scratchpad) {
                window.placement = switch (window.restore_placement) {
                    .tiled => .tiled,
                    .floating => .floating,
                };
            } else {
                window.restore_placement = switch (window.placement) {
                    .floating => .floating,
                    .tiled => .tiled,
                    .fullscreen, .scratchpad => window.restore_placement,
                };
                window.placement = .scratchpad;
            }
        },
    }
    world_tree.repairFocus(world, window.tag);
}

pub fn removeOutputInPlace(world: anytype, output_id: OutputId) !void {
    _ = world.outputs.get(output_id) orelse return error.UnknownOutput;
    for (world.windows.slots.items) |*slot| {
        if (slot.value) |*window| {
            if (window.output == output_id) window.output = null;
        }
    }
    try world.outputs.discard(output_id);
    for (world.tags.slots.items) |slot| if (slot.value) |tag| world_tree.repairFocus(world, tag.id);
}

pub fn removeTagInPlace(world: anytype, tag_id: TagId) !void {
    const tag = world.tags.getConst(tag_id) orelse return error.UnknownTag;
    if (tag.columns.items.len != 0) return error.TagInUse;
    for (world.outputs.slots.items) |slot| {
        if (slot.value) |output| if (output.active_tag == tag_id) return error.TagInUse;
    }
    for (world.windows.slots.items) |slot| {
        if (slot.value) |window| if (window.tag == tag_id) return error.TagInUse;
    }
    try world.tags.discard(tag_id);
}

pub fn removeColumnInPlace(world: anytype, column_id: ColumnId) !void {
    const column = world.columns.getConst(column_id) orelse return error.UnknownColumn;
    if (column.root != null) return error.ColumnInUse;
    const tag = world.tags.get(column.tag) orelse return error.InvalidInvariant;
    const index = indexOfColumn(tag.columns.items, column_id) orelse return error.InvalidInvariant;
    _ = tag.columns.orderedRemove(index);
    try world.columns.discard(column_id);
}

fn requireTag(world: anytype, id: TagId) !void {
    if (world.tags.getConst(id) == null) return error.UnknownTag;
}

fn requireOutput(world: anytype, id: OutputId) !void {
    if (world.outputs.getConst(id) == null) return error.UnknownOutput;
}

fn childIndex(node: *const types.Node, child_id: NodeId) ?usize {
    for (node.children.items, 0..) |child, index| if (child.id == child_id) return index;
    return null;
}

fn indexOfColumn(columns: []const ColumnId, wanted: ColumnId) ?usize {
    for (columns, 0..) |column_id, index| if (column_id == wanted) return index;
    return null;
}

fn checkedCoordinate(value: i64) ?i32 {
    return std.math.cast(i32, value);
}
