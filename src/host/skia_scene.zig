//! Lowering from a laid-out retained scene to scalar Skia operations.
//!
//! Layout belongs to the UI module (`ui.layout`); this host walks the scene in
//! paint order and turns each node's retained box into renderer operations.
//! Containers affect geometry but never become operations. Offsets are applied
//! here, not in layout, so moving a subtree costs one walk and no relayout.
//!
//! The draw list borrows text, icon and gradient bytes from the scene: render
//! it before the scene is next mutated.

const std = @import("std");
const ui = @import("whirlpool-ui");
const graphics = @import("whirlpool-graphics");

const Allocator = std.mem.Allocator;
const DrawOp = graphics.skia.DrawOp;

comptime {
    std.debug.assert(ui.properties.max_polygon_points == graphics.skia.max_polygon_points);
}

pub const Viewport = struct { width: u32, height: u32 };

pub const LowerError = error{InvalidViewport} || Allocator.Error;

pub const OwnedDrawList = struct {
    allocator: Allocator,
    /// Holds what the scene does not: ellipsized copies of truncated text.
    arena: std.heap.ArenaAllocator,
    ops: []DrawOp,

    pub fn drawList(self: *const OwnedDrawList) graphics.skia.DrawList {
        return .{ .ops = self.ops };
    }

    pub fn operationCount(self: *const OwnedDrawList) usize {
        return self.ops.len;
    }

    pub fn deinit(self: *OwnedDrawList) void {
        self.allocator.free(self.ops);
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Text measured by the renderer that will draw it.
pub fn measurer(metrics: graphics.skia.TextMetrics) ui.Measurer {
    const Adapter = struct {
        fn width(context: ?*anyopaque, family: []const u8, text: []const u8, size: f32) f32 {
            return metricsFrom(context).width(family, text, size);
        }
        fn fit(context: ?*anyopaque, family: []const u8, text: []const u8, size: f32, max_width: f32) usize {
            return metricsFrom(context).fit(family, text, size, max_width);
        }
        fn metricsFrom(context: ?*anyopaque) graphics.skia.TextMetrics {
            return .{ .native = @ptrCast(context.?) };
        }
    };
    return .{ .context = @ptrCast(metrics.native), .width_fn = Adapter.width, .fit_fn = Adapter.fit };
}

const ellipsis = "…";

const Lowerer = struct {
    allocator: Allocator,
    scene: *ui.Scene,
    measurer: ui.Measurer,
    arena: std.mem.Allocator,
    ops: *std.ArrayList(DrawOp),

    fn emit(self: *Lowerer, op: DrawOp) Allocator.Error!void {
        try self.ops.append(self.allocator, op);
    }

    fn paint(self: *Lowerer, handle: ui.NodeHandle, dx: f32, dy: f32, inherited_opacity: f32) Allocator.Error!void {
        const node = self.scene.get(handle) orelse return;
        const p = node.props();
        if (!p.visible) return;
        const opacity = inherited_opacity * p.opacity;
        if (opacity == 0) return;
        const x = dx + p.offset_x;
        const y = dy + p.offset_y;
        const box = ui.Box{ .x = node.layout.x + x, .y = node.layout.y + y, .width = node.layout.width, .height = node.layout.height };

        if (p.clip) try self.emit(if (p.clip_shape.len >= 3)
            .{ .push_clip_polygon = place(p.clip_shape, box) }
        else
            .{ .push_clip = toRect(box) });
        switch (node.kind) {
            .shape => if (box.width > 0 and box.height > 0) try self.emit(.{ .rect = .{
                .rect = toRect(box),
                .radius = p.radius,
                .color = colorWithOpacity(p.fill, opacity),
                .center = if (p.fill_center) |center| colorWithOpacity(center, opacity) else null,
            } }),
            .polygon => if (box.width > 0 and box.height > 0 and p.points.len >= 3) try self.emit(.{ .polygon = .{
                .points = place(p.points, box),
                .color = colorWithOpacity(p.fill, opacity),
                // Borrowed from the scene, as text is.
                .gradient = if (p.gradient.len != 0) .{
                    .stops = p.gradient,
                    .left = box.x,
                    .bottom = box.y + box.height,
                    .opacity = opacity,
                } else null,
            } }),
            .text => if (p.text.len != 0) try self.text(handle, box, opacity),
            .icon => if (p.icon_source.len != 0 and box.width > 0 and box.height > 0) try self.emit(.{ .icon = .{
                .source = p.icon_source,
                .rect = toRect(box.inset(p.padding)),
                .opacity = opacity,
            } }),
            .row, .column, .stack => {
                var child = node.first_child;
                while (child) |child_handle| : (child = (self.scene.get(child_handle) orelse break).next_sibling)
                    try self.paint(child_handle, x, y, opacity);
            },
            .spacer => {},
        }
        if (p.clip) try self.emit(.pop_clip);
    }

    fn text(self: *Lowerer, handle: ui.NodeHandle, box: ui.Box, opacity: f32) Allocator.Error!void {
        const node = self.scene.get(handle).?;
        const p = node.props();
        const size: f32 = @floatFromInt(p.font_size);
        const content = box.inset(p.padding);
        var shown: []const u8 = p.text;
        if (p.text_overflow == .ellipsis) {
            const padding: f32 = @floatFromInt(p.padding.left + p.padding.right);
            const natural = if (p.width == null) node.layout.intrinsic[0] - padding else self.measurer.width(p.font_family, p.text, size);
            if (natural > content.width + 0.5) shown = try self.ellipsized(handle, content.width, size);
        }
        // Alignment is relative to the padded content box; the renderer
        // anchors the run, so no glyph positions are computed here.
        try self.emit(.{ .text = .{
            .text = shown,
            .family = p.font_family,
            .x = switch (p.text_align) {
                .start => content.x,
                .center => content.x + content.width / 2,
                .end => content.x + content.width,
            },
            .baseline = switch (p.text_valign) {
                .top => content.y + size,
                .middle => content.y + content.height / 2,
            },
            .size = size,
            .color = colorWithOpacity(p.text_color, opacity),
            .anchor = switch (p.text_align) {
                .start => .start,
                .center => .center,
                .end => .end,
            },
            .vertical = switch (p.text_valign) {
                .top => .baseline,
                .middle => .middle,
            },
        } });
    }

    /// The text cut to `width` with an ellipsis. The cut point is remembered
    /// per node until the width or text changes.
    fn ellipsized(self: *Lowerer, handle: ui.NodeHandle, width: f32, size: f32) Allocator.Error![]const u8 {
        const node = self.scene.get(handle).?;
        const state = self.scene.getLayoutMut(handle).?;
        const value = node.props().text;
        if (state.fit_width != width or state.fit_bytes > value.len) {
            const room = width - self.measurer.width(node.props().font_family, ellipsis, size);
            state.fit_bytes = if (room > 0) self.measurer.fit(node.props().font_family, value, size, room) else 0;
            state.fit_width = width;
        }
        return std.mem.concat(self.arena, u8, &.{ value[0..state.fit_bytes], ellipsis });
    }
};

/// Lay out `scene` for `viewport` (if anything changed) and lower it.
pub fn lower(allocator: Allocator, scene: *ui.Scene, viewport: Viewport, text_measurer: ui.Measurer) LowerError!OwnedDrawList {
    if (viewport.width == 0 or viewport.height == 0) return error.InvalidViewport;
    ui.layout.update(scene, .{ .width = @floatFromInt(viewport.width), .height = @floatFromInt(viewport.height) }, text_measurer);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var ops = std.ArrayList(DrawOp).empty;
    errdefer ops.deinit(allocator);
    var lowerer = Lowerer{
        .allocator = allocator,
        .scene = scene,
        .measurer = text_measurer,
        .arena = arena.allocator(),
        .ops = &ops,
    };
    var root = scene.firstRoot();
    while (root) |handle| : (root = (scene.get(handle) orelse break).next_sibling)
        try lowerer.paint(handle, 0, 0, 1);
    return .{ .allocator = allocator, .arena = arena, .ops = try ops.toOwnedSlice(allocator) };
}

/// Box-relative points (fractions plus pixel offsets) on the surface.
fn place(points: ui.Polygon, box: ui.Box) graphics.skia.Polygon {
    var polygon = graphics.skia.Polygon{ .len = points.len };
    for (points.slice(), 0..) |point, index| polygon.points[index] = .{
        .x = box.x + point.x * box.width + point.dx,
        .y = box.y + point.y * box.height + point.dy,
    };
    return polygon;
}

fn toRect(box: ui.Box) graphics.skia.Rect {
    return .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
}

fn colorWithOpacity(color: ui.Color, opacity: f32) graphics.skia.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * opacity };
}

const testing = std.testing;

const Fixture = struct {
    scene: ui.Scene,
    mount: ui.MountContext,

    fn init(self: *Fixture) !void {
        self.scene = ui.Scene.init(testing.allocator);
        self.mount = try self.scene.mount();
    }

    fn deinit(self: *Fixture) void {
        self.mount.deinit();
        self.scene.deinit();
    }

    fn add(self: *Fixture, kind: ui.NodeKind, parent: ?ui.NodeHandle, values: []const ui.PropertyValue) !ui.NodeHandle {
        const handle = try self.mount.create(kind, parent);
        for (values) |value| {
            const bytes: ?[]u8 = switch (value) {
                .text => |item| try testing.allocator.dupe(u8, item),
                .icon_source, .font_family, .gradient => |item| try testing.allocator.dupe(u8, item),
                else => null,
            };
            try self.scene.applyProperty(handle, value, bytes);
        }
        return handle;
    }

    fn lowered(self: *Fixture, width: u32, height: u32) !OwnedDrawList {
        return lower(testing.allocator, &self.scene, .{ .width = width, .height = height }, ui.Measurer.estimate);
    }
};

const red = ui.Color.rgba(1, 0, 0, 1);

test "shapes fill their laid-out boxes and polygons are box-relative" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const row = try f.add(.row, null, &.{.{ .padding = .{ .left = 4 } }});
    _ = try f.add(.shape, row, &.{ .{ .width = 10 }, .{ .fill = red } });
    _ = try f.add(.polygon, row, &.{ .{ .width = 40 }, .{ .fill = red }, .{ .points = blk: {
        var polygon = ui.Polygon{ .len = 3 };
        polygon.points[0] = .{ .x = 0.25, .y = 0 };
        polygon.points[1] = .{ .x = 1.25, .y = 0 };
        polygon.points[2] = .{ .x = 0, .y = 1 };
        break :blk polygon;
    } } });
    var list = try f.lowered(100, 20);
    defer list.deinit();
    try testing.expectEqual(graphics.skia.Rect{ .x = 4, .y = 0, .width = 10, .height = 20 }, list.ops[0].rect.rect);
    try testing.expectEqual(@as(f32, 24), list.ops[1].polygon.points.points[0].x);
    try testing.expectEqual(@as(f32, 64), list.ops[1].polygon.points.points[1].x);
}

test "offsets and clips move and bound a subtree; invisible nodes are skipped" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const viewport = try f.add(.stack, null, &.{ .{ .width = 50 }, .{ .clip = true } });
    const strip = try f.add(.row, viewport, &.{.{ .offset_x = -20 }});
    _ = try f.add(.shape, strip, &.{ .{ .width = 30 }, .{ .fill = red } });
    _ = try f.add(.shape, strip, &.{ .{ .width = 30 }, .{ .fill = red }, .{ .visible = false } });
    _ = try f.add(.shape, strip, &.{ .{ .width = 30 }, .{ .fill = red }, .{ .opacity = 0 } });
    var list = try f.lowered(100, 20);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 3), list.ops.len);
    try testing.expectEqual(graphics.skia.Rect{ .x = 0, .y = 0, .width = 50, .height = 20 }, list.ops[0].push_clip);
    try testing.expectEqual(@as(f32, -20), list.ops[1].rect.rect.x);
    try testing.expect(list.ops[2] == .pop_clip);
}

test "a clip shape cuts content along its edges instead of the box" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var shape = ui.Polygon{ .len = 4 };
    shape.points[0] = .{ .x = 0, .y = 0, .dx = 6 };
    shape.points[1] = .{ .x = 1, .y = 0, .dx = 6 };
    shape.points[2] = .{ .x = 1, .y = 1 };
    shape.points[3] = .{ .x = 0, .y = 1 };
    const list = try f.add(.row, null, &.{ .{ .width = 50 }, .{ .clip = true }, .{ .clip_shape = shape } });
    _ = try f.add(.shape, list, &.{ .{ .width = 80 }, .{ .fill = red } });
    var lowered = try f.lowered(100, 20);
    defer lowered.deinit();
    const clip = lowered.ops[0].push_clip_polygon;
    try testing.expectEqual(@as(u8, 4), clip.len);
    try testing.expectEqual(graphics.skia.Point{ .x = 56, .y = 0 }, clip.points[1]);
    try testing.expectEqual(graphics.skia.Point{ .x = 50, .y = 20 }, clip.points[2]);
    try testing.expect(lowered.ops[2] == .pop_clip);
}

test "text wider than its box is cut with an ellipsis when asked" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const row = try f.add(.row, null, &.{});
    _ = try f.add(.text, row, &.{ .{ .text = "abcdefghij" }, .{ .font_size = 10 }, .{ .width = 30 }, .{ .text_overflow = .ellipsis } });
    _ = try f.add(.text, row, &.{ .{ .text = "abcdefghij" }, .{ .font_size = 10 }, .{ .width = 30 } });
    _ = try f.add(.text, row, &.{ .{ .text = "ab" }, .{ .font_size = 10 }, .{ .text_overflow = .ellipsis } });
    var list = try f.lowered(200, 20);
    defer list.deinit();
    // 30px holds 5.45 characters: four plus the ellipsis.
    try testing.expectEqualStrings("abcd…", list.ops[0].text.text);
    try testing.expectEqualStrings("abcdefghij", list.ops[1].text.text);
    try testing.expectEqualStrings("ab", list.ops[2].text.text);
}

test "a text node's font family reaches its draw operation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.add(.text, null, &.{ .{ .text = "x" }, .{ .font_family = "Iosevka" } });
    var lowered = try f.lowered(100, 20);
    defer lowered.deinit();
    try testing.expectEqualStrings("Iosevka", lowered.ops[0].text.family);
}

test "aligned text is anchored to its padded box" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const column = try f.add(.column, null, &.{});
    _ = try f.add(.text, column, &.{ .{ .text = "x" }, .{ .height = 20 }, .{ .padding = .{ .left = 2, .right = 4 } }, .{ .text_align = .end }, .{ .text_valign = .middle } });
    var list = try f.lowered(100, 40);
    defer list.deinit();
    try testing.expectEqual(@as(f32, 96), list.ops[0].text.x);
    try testing.expectEqual(@as(f32, 10), list.ops[0].text.baseline);
    try testing.expectEqual(graphics.skia.TextAnchor.end, list.ops[0].text.anchor);
}

test "lowering rejects an empty viewport" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectError(error.InvalidViewport, f.lowered(0, 10));
}
