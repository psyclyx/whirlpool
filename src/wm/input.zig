//! Protocol-free input observations delivered to policy.

const ids = @import("ids.zig");
const types = @import("types.zig");

pub const PointerGestureKind = enum { move, resize };
pub const PointerGesture = struct {
    kind: PointerGestureKind,
    window: ids.WindowId,
    delta: types.Point = .{ .x = 0, .y = 0 },
    edges: ?types.ResizeEdges = null,
};

test "pointer observations contain no layout destination" {
    const value: PointerGesture = .{
        .kind = .move,
        .window = ids.WindowId.fromParts(1, 1),
        .delta = .{ .x = 2, .y = -1 },
    };
    try @import("std").testing.expectEqual(@as(i32, 2), value.delta.x);
}
