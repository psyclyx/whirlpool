//! Pure window-tree projection and camera geometry for the shell window strip.

const wm = @import("whirlpool-wm");

pub const max_tokens = 96;
pub const gap: u32 = 4;
pub const window_min_width: u32 = 104;
pub const window_max_width: u32 = 220;
pub const group_open_width: u32 = 34;
pub const group_close_width: u32 = 12;

pub const Kind = enum { group_open, group_close, window };

pub const Token = struct {
    kind: Kind,
    x: u32,
    width: u32,
    label: []const u8 = "",
    window: ?wm.WindowId = null,
    focused: bool = false,
};

pub const Strip = struct {
    tokens: [max_tokens]Token = undefined,
    len: usize = 0,
    content_width: u32 = 1,
    focused_index: ?usize = null,

    pub fn slice(self: *const Strip) []const Token {
        return self.tokens[0..self.len];
    }

    pub fn tokenAt(self: *const Strip, x: u32) ?Token {
        for (self.slice()) |token| {
            if (x >= token.x and x < token.x + token.width) return token;
        }
        return null;
    }

    pub fn reflow(self: *Strip) void {
        var cursor: u32 = 0;
        for (self.tokens[0..self.len]) |*token| {
            if (cursor != 0) cursor +|= gap;
            token.x = cursor;
            cursor +|= token.width;
        }
        self.content_width = @max(1, cursor);
    }
};

pub fn widthForAppId(app_id: []const u8) u32 {
    const text_width = @as(u32, @intCast(@min(app_id.len, 64))) * 7;
    return @min(window_max_width, @max(window_min_width, 48 + text_width));
}

pub fn build(world: *const wm.World, tag_id: wm.TagId, focused: ?wm.WindowId) Strip {
    var builder = Builder{ .world = world, .focused = focused };
    const tag = world.getTag(tag_id) orelse return builder.finish();
    const start = builder.checkpoint();
    _ = builder.append(.group_open, group_open_width, "(:h", null);
    var has_window = false;
    for (tag.columns.items) |column_id| {
        const column = world.getColumn(column_id) orelse continue;
        has_window = builder.appendNode(column.root) or has_window;
    }
    if (has_window) {
        _ = builder.append(.group_close, group_close_width, ")", null);
    } else {
        builder.restore(start);
    }
    return builder.finish();
}

pub fn reveal(offset: u32, viewport_width: u32, strip: *const Strip) u32 {
    const maximum = strip.content_width -| viewport_width;
    var result = @min(offset, maximum);
    const focused_index = strip.focused_index orelse return result;
    const token = strip.tokens[focused_index];
    if (token.x < result) {
        result = token.x;
    } else if (token.x + token.width > result +| viewport_width) {
        result = (token.x + token.width) -| viewport_width;
    }
    return @min(result, maximum);
}

pub fn pan(offset: u32, delta: i32, viewport_width: u32, content_width: u32) u32 {
    const maximum = content_width -| viewport_width;
    const moved = @as(i64, offset) + delta;
    return @intCast(@min(@as(i64, maximum), @max(0, moved)));
}

const Checkpoint = struct { len: usize, cursor: u32, focused_index: ?usize };

const Builder = struct {
    world: *const wm.World,
    focused: ?wm.WindowId,
    result: Strip = .{},
    cursor: u32 = 0,

    fn checkpoint(self: *const Builder) Checkpoint {
        return .{ .len = self.result.len, .cursor = self.cursor, .focused_index = self.result.focused_index };
    }

    fn restore(self: *Builder, saved: Checkpoint) void {
        self.result.len = saved.len;
        self.cursor = saved.cursor;
        self.result.focused_index = saved.focused_index;
    }

    fn appendNode(self: *Builder, maybe_node: ?wm.NodeId) bool {
        const node = self.world.getNode(maybe_node orelse return false) orelse return false;
        if (node.window) |window_id| {
            const window = self.world.getWindow(window_id) orelse return false;
            if (window.lifecycle != .managed or window.placement == .scratchpad) return false;
            return self.append(.window, window_min_width, "", window_id);
        }

        const saved = self.checkpoint();
        const label: []const u8 = if (node.mode == .tabbed)
            "(:t"
        else if (node.axis == .horizontal)
            "(:h"
        else
            "(:v";
        if (!self.append(.group_open, group_open_width, label, null)) return false;
        var has_window = false;
        for (node.children.items) |child| has_window = self.appendNode(child.id) or has_window;
        if (!has_window) {
            self.restore(saved);
            return false;
        }
        _ = self.append(.group_close, group_close_width, ")", null);
        return true;
    }

    fn append(self: *Builder, kind: Kind, width: u32, label: []const u8, window: ?wm.WindowId) bool {
        if (self.result.len == max_tokens) return false;
        if (self.result.len != 0) self.cursor +|= gap;
        const index = self.result.len;
        const focused = window != null and self.focused != null and window.? == self.focused.?;
        self.result.tokens[index] = .{
            .kind = kind,
            .x = self.cursor,
            .width = width,
            .label = label,
            .window = window,
            .focused = focused,
        };
        if (focused) self.result.focused_index = index;
        self.result.len += 1;
        self.cursor +|= width;
        return true;
    }

    fn finish(self: *Builder) Strip {
        self.result.content_width = @max(1, self.cursor);
        return self.result;
    }
};

test "camera reveals the complete focused item and clamps to content" {
    var strip = Strip{ .content_width = 500, .len = 1, .focused_index = 0 };
    strip.tokens[0] = .{ .kind = .window, .x = 310, .width = 148 };
    try @import("std").testing.expectEqual(@as(u32, 258), reveal(0, 200, &strip));
    try @import("std").testing.expectEqual(@as(u32, 300), reveal(900, 200, &strip));
    strip.tokens[0].x = 40;
    try @import("std").testing.expectEqual(@as(u32, 40), reveal(200, 200, &strip));
}

test "manual panning stays inside the strip" {
    try @import("std").testing.expectEqual(@as(u32, 80), pan(20, 60, 100, 300));
    try @import("std").testing.expectEqual(@as(u32, 0), pan(20, -60, 100, 300));
    try @import("std").testing.expectEqual(@as(u32, 200), pan(190, 60, 100, 300));
}

test "projection exposes tag and nested group modes around fixed-width windows" {
    const std = @import("std");
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, column);
    try world.manageWindow(second, column);

    const strip = build(&world, tag, second);
    try std.testing.expectEqualStrings("(:h", strip.tokens[0].label);
    try std.testing.expectEqualStrings("(:v", strip.tokens[1].label);
    try std.testing.expectEqual(Kind.window, strip.tokens[2].kind);
    try std.testing.expectEqual(window_min_width, strip.tokens[2].width);
    try std.testing.expectEqual(Kind.window, strip.tokens[3].kind);
    try std.testing.expect(strip.tokens[3].focused);
    try std.testing.expectEqualStrings(")", strip.tokens[4].label);
    try std.testing.expectEqualStrings(")", strip.tokens[5].label);
}

test "application id determines a bounded window item width" {
    const std = @import("std");
    try std.testing.expectEqual(window_min_width, widthForAppId("foot"));
    try std.testing.expect(widthForAppId("org.gnu.Emacs") > widthForAppId("foot"));
    try std.testing.expectEqual(window_max_width, widthForAppId("org.example.AnExtremelyLongApplicationIdentifierThatMustBeBounded"));
}
