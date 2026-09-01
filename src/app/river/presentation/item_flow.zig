//! Generic horizontal geometry for bounded Lua-supplied display items.

const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");

pub const max_items = 96;
pub const gap: u32 = 4;

pub const Item = struct {
    x: u32,
    width: u32,
    style: script.layout_projection.Label = .{},
    text: script.layout_projection.Label = .{},
    detail: script.layout_projection.Label = .{},
    window: ?wm.WindowId = null,
    focused: bool = false,
    overlay: bool = false,
    action: script.layout_projection.Label = .{},
    args: [script.layout_projection.max_action_args]script.layout_projection.Label = [_]script.layout_projection.Label{.{}} ** script.layout_projection.max_action_args,
    arg_count: u8 = 0,
};

pub const Flow = struct {
    items: [max_items]Item = undefined,
    len: usize = 0,
    content_width: u32 = 1,
    focused_index: ?usize = null,

    pub fn slice(self: *const Flow) []const Item {
        return self.items[0..self.len];
    }

    pub fn itemAt(self: *const Flow, x: u32) ?Item {
        for (self.slice()) |item| {
            if (item.overlay) continue;
            if (x >= item.x and x < item.x +| item.width) return item;
        }
        return null;
    }
};

pub fn fromProjection(projection: *const script.LayoutProjection) Flow {
    var result: Flow = .{};
    var cursor: u32 = 0;
    var has_flow_item = false;
    for (projection.items.items) |source| {
        if (result.len == max_items) break;
        if (!source.overlay and has_flow_item) cursor +|= gap;
        const index = result.len;
        result.items[index] = .{
            .x = cursor,
            .width = source.width,
            .style = source.style,
            .text = source.text,
            .detail = source.detail,
            .window = source.window,
            .focused = source.focused,
            .overlay = source.overlay,
            .action = source.action,
            .args = source.args,
            .arg_count = source.arg_count,
        };
        if (source.focused) result.focused_index = index;
        if (!source.overlay) {
            cursor +|= source.width;
            has_flow_item = true;
        }
        result.len += 1;
    }
    result.content_width = @max(1, cursor);
    return result;
}

test "overlay items anchor at flow boundaries without changing content geometry" {
    var projection = script.LayoutProjection.init(@import("std").testing.allocator);
    defer projection.deinit();
    try projection.items.append(projection.allocator, .{ .width = 20 });
    try projection.items.append(projection.allocator, .{ .width = 3, .overlay = true });
    try projection.items.append(projection.allocator, .{ .width = 30 });

    const flow = fromProjection(&projection);
    try @import("std").testing.expectEqual(@as(u32, 20), flow.items[1].x);
    try @import("std").testing.expectEqual(@as(u32, 24), flow.items[2].x);
    try @import("std").testing.expectEqual(@as(u32, 54), flow.content_width);
    try @import("std").testing.expect(flow.itemAt(20) == null);
}

pub fn ensureVisible(offset: u32, viewport_width: u32, flow: *const Flow) u32 {
    const maximum = flow.content_width -| viewport_width;
    var result = @min(offset, maximum);
    const focused_index = flow.focused_index orelse return result;
    const item = flow.items[focused_index];
    if (item.x < result) {
        result = item.x;
    } else if (item.x +| item.width > result +| viewport_width) {
        result = (item.x +| item.width) -| viewport_width;
    }
    return @min(result, maximum);
}

pub fn scroll(offset: u32, delta: i32, viewport_width: u32, content_width: u32) u32 {
    const maximum = content_width -| viewport_width;
    const moved = @as(i64, offset) + delta;
    return @intCast(@min(@as(i64, maximum), @max(0, moved)));
}

pub const EdgeClipping = struct { leading: u32, trailing: u32 };

pub fn edgeClipping(offset: u32, viewport_width: u32, content_width: u32, limit: u32) EdgeClipping {
    return .{
        .leading = @min(offset, limit),
        .trailing = @min(content_width -| (offset +| viewport_width), limit),
    };
}

test "focused item is kept inside a bounded viewport" {
    var flow = Flow{ .content_width = 500, .len = 1, .focused_index = 0 };
    flow.items[0] = .{ .x = 310, .width = 148 };
    try @import("std").testing.expectEqual(@as(u32, 258), ensureVisible(0, 200, &flow));
    try @import("std").testing.expectEqual(@as(u32, 300), ensureVisible(900, 200, &flow));
}

test "manual scrolling stays inside generic content bounds" {
    try @import("std").testing.expectEqual(@as(u32, 80), scroll(20, 60, 100, 300));
    try @import("std").testing.expectEqual(@as(u32, 0), scroll(20, -60, 100, 300));
    try @import("std").testing.expectEqual(@as(u32, 200), scroll(190, 60, 100, 300));
}

test "edge clipping reports only obscured content up to the visual limit" {
    try @import("std").testing.expectEqual(EdgeClipping{ .leading = 0, .trailing = 0 }, edgeClipping(0, 300, 300, 24));
    try @import("std").testing.expectEqual(EdgeClipping{ .leading = 5, .trailing = 7 }, edgeClipping(5, 100, 112, 24));
    try @import("std").testing.expectEqual(EdgeClipping{ .leading = 24, .trailing = 24 }, edgeClipping(40, 100, 200, 24));
}
