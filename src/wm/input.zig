//! Pure WM input planning.
//!
//! This module is the typed boundary between an input action and the semantic
//! command vocabulary. It deliberately does not know about seats, River
//! objects, or command execution.

const command = @import("command.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const Command = command.Command;
pub const Axis = types.Axis;
pub const Direction = types.Direction;
pub const Point = types.Point;
pub const ResizeEdges = types.ResizeEdges;
pub const ColumnId = ids.ColumnId;
pub const NodeId = ids.NodeId;
pub const WindowId = ids.WindowId;

pub const MoveAction = struct {
    node: NodeId,
    column: ColumnId,
};

pub const ResizeAction = union(enum) {
    column: struct {
        column: ColumnId,
        width: f32,
    },
    split: struct {
        split: NodeId,
        child: NodeId,
        weight: f32,
    },
};

pub const PointerGestureKind = enum {
    move,
    resize,
};

/// A protocol-free description of one pointer gesture observation. `edges`
/// remains an optional raw observation so under-specified input stays visible;
/// planning validates and converts it to the WM-owned ResizeEdges type.
pub const PointerGesture = struct {
    kind: PointerGestureKind,
    window: WindowId,
    delta: Point = .{ .x = 0, .y = 0 },
    edges: ?u32 = null,
};

pub const Action = union(enum) {
    move: MoveAction,
    resize: ResizeAction,
    pointer: PointerGesture,
};

pub const MissingExecutionReason = enum {
    pointer_resize_missing_edges,
    pointer_resize_invalid_edges,
};

pub const MissingExecution = struct {
    reason: MissingExecutionReason,
    gesture: PointerGesture,
};

pub const ActionPlan = union(enum) {
    command: Command,
    missing_execution: MissingExecution,
};

/// Lower one typed action into a semantic WM command, or preserve the exact
/// pointer gesture as an explicit execution gap when its geometry is not
/// sufficiently specified. This function is pure: it does not inspect or
/// mutate a World.
pub fn planAction(action: Action) ActionPlan {
    return switch (action) {
        .move => |value| .{ .command = .{ .tree = .{ .move_node = .{
            .node = value.node,
            .column = value.column,
        } } } },
        .resize => |value| switch (value) {
            .column => |resize| .{ .command = .{ .geometry = .{ .resize_column = .{
                .column = resize.column,
                .width = resize.width,
            } } } },
            .split => |resize| .{ .command = .{ .geometry = .{ .resize_split = .{
                .split = resize.split,
                .child = resize.child,
                .weight = resize.weight,
            } } } },
        },
        .pointer => |gesture| switch (gesture.kind) {
            .move => .{ .command = .{ .geometry = .{ .move_floating = .{
                .window = gesture.window,
                .delta = gesture.delta,
            } } } },
            .resize => {
                const raw_edges = gesture.edges orelse return .{ .missing_execution = .{
                    .reason = .pointer_resize_missing_edges,
                    .gesture = gesture,
                } };
                const edges = ResizeEdges.fromBits(raw_edges) catch return .{ .missing_execution = .{
                    .reason = .pointer_resize_invalid_edges,
                    .gesture = gesture,
                } };
                return .{ .command = .{ .geometry = .{ .resize_floating = .{
                    .window = gesture.window,
                    .edges = edges,
                    .delta = gesture.delta,
                } } } };
            },
        },
    };
}

test "move and resize actions lower to current semantic commands" {
    const node = NodeId.fromParts(4, 1);
    const column = ColumnId.fromParts(7, 2);
    const move = planAction(.{ .move = .{ .node = node, .column = column } });
    switch (move) {
        .command => |value| switch (value) {
            .tree => |tree| switch (tree) {
                .move_node => |payload| {
                    try @import("std").testing.expectEqual(node, payload.node);
                    try @import("std").testing.expectEqual(column, payload.column);
                },
                else => return error.UnexpectedCommand,
            },
            else => return error.UnexpectedCommand,
        },
        .missing_execution => return error.UnexpectedExecutionGap,
    }

    const split = NodeId.fromParts(8, 3);
    const child = NodeId.fromParts(9, 3);
    const resize = planAction(.{ .resize = .{ .split = .{
        .split = split,
        .child = child,
        .weight = 1.5,
    } } });
    switch (resize) {
        .command => |value| switch (value) {
            .geometry => |geometry| switch (geometry) {
                .resize_split => |payload| {
                    try @import("std").testing.expectEqual(split, payload.split);
                    try @import("std").testing.expectEqual(child, payload.child);
                    try @import("std").testing.expectEqual(@as(f32, 1.5), payload.weight);
                },
                else => return error.UnexpectedCommand,
            },
            else => return error.UnexpectedCommand,
        },
        .missing_execution => return error.UnexpectedExecutionGap,
    }
}

test "pointer gestures lower to typed floating geometry commands" {
    const window = WindowId.fromParts(12, 1);
    const move = PointerGesture{
        .kind = .move,
        .window = window,
        .delta = .{ .x = 16, .y = -4 },
    };
    switch (planAction(.{ .pointer = move })) {
        .command => |value| switch (value) {
            .geometry => |geometry| switch (geometry) {
                .move_floating => |payload| {
                    try @import("std").testing.expectEqual(window, payload.window);
                    try @import("std").testing.expectEqual(Point{ .x = 16, .y = -4 }, payload.delta);
                },
                else => return error.UnexpectedCommand,
            },
            else => return error.UnexpectedCommand,
        },
        .missing_execution => return error.PointerMoveWasNotLowered,
    }

    const gesture = PointerGesture{
        .kind = .resize,
        .window = window,
        .delta = .{ .x = 16, .y = -4 },
        .edges = 5,
    };

    switch (planAction(.{ .pointer = gesture })) {
        .command => |value| switch (value) {
            .geometry => |geometry| switch (geometry) {
                .resize_floating => |payload| {
                    try @import("std").testing.expectEqual(window, payload.window);
                    try @import("std").testing.expectEqual(@as(u32, 5), payload.edges.bits());
                    try @import("std").testing.expectEqual(Point{ .x = 16, .y = -4 }, payload.delta);
                },
                else => return error.UnexpectedCommand,
            },
            else => return error.UnexpectedCommand,
        },
        .missing_execution => return error.ResizeGestureWasNotLowered,
    }

    const missing_edges = PointerGesture{ .kind = .resize, .window = window };
    switch (planAction(.{ .pointer = missing_edges })) {
        .missing_execution => |gap| try @import("std").testing.expectEqual(
            MissingExecutionReason.pointer_resize_missing_edges,
            gap.reason,
        ),
        .command => return error.UnderspecifiedGestureWasLowered,
    }
}
