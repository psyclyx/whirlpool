//! Semantic policy commands grouped by the aggregate they authorize.

const ids = @import("ids.zig");
const types = @import("types.zig");

pub const ColumnWidthStep = enum { previous, next };
pub const SendTarget = struct {
    window: ids.WindowId,
    tag: ids.TagId,
    output: ?ids.OutputId = null,
};
pub const Directional = struct { output: ids.OutputId, direction: types.Direction };

pub const Focus = union(enum) {
    window: ids.WindowId,
    direction: Directional,
    mark: []const u8,
};

pub const Tree = union(enum) {
    swap_direction: Directional,
    insert_window: struct { window: ids.WindowId, column: ids.ColumnId },
    move_node: struct { node: ids.NodeId, column: ids.ColumnId },
    swap_nodes: struct { first: ids.NodeId, second: ids.NodeId },
    wrap_node: struct { node: ids.NodeId, mode: types.ContainerMode, axis: types.Axis },
    unwrap_node: ids.NodeId,
    set_container_mode: struct { node: ids.NodeId, mode: types.ContainerMode, axis: types.Axis },
    set_active_tab: struct { container: ids.NodeId, child: ids.NodeId },
    absorb: Directional,
    eject: ids.NodeId,
    expel: struct { node: ids.NodeId, direction: types.Direction },
    remove_column: ids.ColumnId,
};

pub const Geometry = union(enum) {
    resize_column: struct { column: ids.ColumnId, width: f32 },
    cycle_column_width: struct { column: ids.ColumnId, step: ColumnWidthStep },
    resize_split: struct { split: ids.NodeId, child: ids.NodeId, weight: f32 },
    move_floating: struct { window: ids.WindowId, delta: types.Point },
    resize_floating: struct { window: ids.WindowId, edges: types.ResizeEdges, delta: types.Point },
    set_camera_target: struct { tag: ids.TagId, target: f32 },
};

pub const Tag = union(enum) {
    activate: struct { output: ids.OutputId, tag: ids.TagId },
    toggle: struct { output: ids.OutputId, tag: ids.TagId },
    rename: struct { tag: ids.TagId, name: []const u8 },
    remove: ids.TagId,
};

pub const Mark = union(enum) {
    set: struct { window: ids.WindowId, name: []const u8 },
    clear: struct { window: ids.WindowId, name: []const u8 },
};

pub const Transfer = union(enum) {
    send_window: SendTarget,
    send_focused: struct { source_output: ids.OutputId, tag: ids.TagId, output: ?ids.OutputId = null },
    summon_window: struct { window: ids.WindowId, output: ids.OutputId },
    summon_mark: struct { name: []const u8, output: ids.OutputId },
};

pub const Output = union(enum) {
    update: struct {
        output: ids.OutputId,
        active_tag: ids.TagId,
        bounds: types.Rect,
        usable: types.Rect,
        configuration: types.OutputConfig = .{},
    },
    configure: struct { output: ids.OutputId, configuration: types.OutputConfig },
    remove: ids.OutputId,
};

pub const Window = union(enum) {
    set_output: struct { window: ids.WindowId, output: ?ids.OutputId },
    set_placement: struct { window: ids.WindowId, placement: types.Placement },
    transition_placement: struct { window: ids.WindowId, transition: types.PlacementTransition },
    update_sizing: struct {
        window: ids.WindowId,
        hints: types.SizeHints,
        actual: ?types.Size,
        proposed: ?types.Size,
    },
    begin_close: ids.WindowId,
    destroy: ids.WindowId,
};

pub const Command = union(enum) {
    focus: Focus,
    tree: Tree,
    geometry: Geometry,
    tag: Tag,
    mark: Mark,
    transfer: Transfer,
    output: Output,
    window: Window,
};

pub const Batch = []const Command;

test "commands make aggregate authority explicit" {
    const value: Command = .{ .geometry = .{ .resize_split = .{
        .split = types.NodeId.fromParts(1, 1),
        .child = types.NodeId.fromParts(2, 1),
        .weight = 2,
    } } };
    try @import("std").testing.expectEqual(@as(f32, 2), value.geometry.resize_split.weight);
}
