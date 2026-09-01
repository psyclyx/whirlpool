//! Layout and lowering from retained UI snapshots to scalar Skia operations.
//!
//! The retained tree is renderer-neutral. This host performs the small flex
//! layout pass needed by surfaces, then emits a complete paint list in tree
//! order. Containers affect geometry but never become renderer operations.

const std = @import("std");
const ui = @import("whirlpool-ui");
const graphics = @import("whirlpool-graphics");

const Allocator = std.mem.Allocator;
const DrawList = graphics.skia.DrawList;
const DrawOp = graphics.skia.DrawOp;

comptime {
    std.debug.assert(ui.properties.max_polygon_points == graphics.skia.max_polygon_points);
}

pub const Viewport = struct { width: u32, height: u32 };

pub const LowerError = error{
    InvalidViewport,
    InvalidDimensions,
    InvalidColor,
    InvalidOpacity,
    InvalidFontSize,
    InvalidPolygon,
};

pub const OwnedDrawList = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    ops: []DrawOp,

    pub fn drawList(self: *const OwnedDrawList) DrawList {
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

const Box = struct { x: f32, y: f32, width: f32, height: f32 };
const Axis = enum { horizontal, vertical };

const Lowerer = struct {
    allocator: Allocator,
    snapshots: []const ui.NodeSnapshot,
    arena: *std.heap.ArenaAllocator,
    ops: *std.ArrayList(DrawOp),

    fn layoutNode(self: *Lowerer, index: usize, offered: Box, inherited_opacity: f32) (LowerError || Allocator.Error)!void {
        const snapshot = self.snapshots[index];
        try validateSnapshot(snapshot);
        const properties = snapshot.properties;
        const box = Box{
            .x = offered.x + properties.offset_x,
            .y = offered.y,
            .width = if (properties.width) |value| try dimension(value) else offered.width,
            .height = if (properties.height) |value| try dimension(value) else offered.height,
        };
        const opacity = inherited_opacity * properties.opacity;
        if (opacity == 0) return;

        if (properties.clip) try self.ops.append(self.allocator, .{ .push_clip = toRect(box) });

        switch (snapshot.kind) {
            .shape => if (box.width > 0 and box.height > 0) try self.ops.append(self.allocator, .{ .rect = .{
                .rect = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height },
                .radius = properties.radius,
                .color = colorWithOpacity(properties.fill, opacity),
            } }),
            .polygon => if (box.width > 0 and box.height > 0 and properties.points.len >= 3) {
                var polygon = graphics.skia.Polygon{ .len = properties.points.len };
                for (properties.points.slice(), 0..) |point, point_index| {
                    polygon.points[point_index] = .{
                        .x = box.x + point.x * box.width,
                        .y = box.y + point.y * box.height,
                    };
                }
                try self.ops.append(self.allocator, .{ .polygon = .{
                    .points = polygon,
                    .color = colorWithOpacity(properties.fill, opacity),
                } });
            },
            .text => if (properties.text.len != 0) {
                const size = try fontSize(properties.font_size);
                const text = try self.arena.allocator().dupe(u8, properties.text);
                try self.ops.append(self.allocator, .{ .text = .{
                    .text = text,
                    .x = box.x + @as(f32, @floatFromInt(properties.padding.left)),
                    .baseline = box.y + @as(f32, @floatFromInt(properties.padding.top)) + size,
                    .size = size,
                    .color = colorWithOpacity(properties.text_color, opacity),
                } });
            },
            .icon => if (properties.icon_source.len != 0 and box.width > 0 and box.height > 0) {
                const source = try self.arena.allocator().dupe(u8, properties.icon_source);
                try self.ops.append(self.allocator, .{ .icon = .{
                    .source = source,
                    .rect = toRect(inset(box, properties.padding)),
                    .opacity = opacity,
                } });
            },
            .row => try self.layoutFlow(index, box, .horizontal, opacity),
            .column => try self.layoutFlow(index, box, .vertical, opacity),
            .stack => try self.layoutStack(index, box, opacity),
            .spacer => {},
        }
        if (properties.clip) try self.ops.append(self.allocator, .pop_clip);
    }

    fn layoutFlow(self: *Lowerer, parent_index: usize, box: Box, axis: Axis, opacity: f32) (LowerError || Allocator.Error)!void {
        const properties = self.snapshots[parent_index].properties;
        const content = inset(box, properties.padding);
        const child_count = self.childCount(parent_index);
        if (child_count == 0) return;

        const gap: f32 = @floatFromInt(properties.gap);
        const total_gap = gap * @as(f32, @floatFromInt(child_count - 1));
        const available_main = @max(0, mainSize(content, axis) - total_gap);
        var fixed: f32 = 0;
        var flex_total: u64 = 0;
        var auto_count: usize = 0;

        for (self.snapshots, 0..) |child, child_index| {
            if (!isChild(child, self.snapshots[parent_index])) continue;
            const preferred = try self.intrinsic(child_index, axis);
            if (child.properties.flex != 0) {
                flex_total += child.properties.flex;
            } else if (preferred > 0) {
                fixed += preferred;
            } else {
                auto_count += 1;
            }
        }

        const remaining = @max(0, available_main - fixed);
        const auto_share = if (flex_total == 0 and auto_count != 0)
            remaining / @as(f32, @floatFromInt(auto_count))
        else
            0;
        var cursor = if (axis == .horizontal) content.x else content.y;

        for (self.snapshots, 0..) |child, child_index| {
            if (!isChild(child, self.snapshots[parent_index])) continue;
            const preferred_main = try self.intrinsic(child_index, axis);
            const explicit_main = if (axis == .horizontal) child.properties.width else child.properties.height;
            const child_main = if (child_count == 1 and explicit_main == null)
                available_main
            else if (child.properties.flex != 0 and flex_total != 0)
                remaining * @as(f32, @floatFromInt(child.properties.flex)) / @as(f32, @floatFromInt(flex_total))
            else if (preferred_main > 0)
                preferred_main
            else
                auto_share;
            const cross_available = crossSize(content, axis);
            const explicit_cross = if (axis == .horizontal) child.properties.height else child.properties.width;
            const child_cross = if (explicit_cross) |value|
                @min(try dimension(value), cross_available)
            else
                cross_available;
            const child_box = if (axis == .horizontal)
                Box{ .x = cursor, .y = content.y, .width = child_main, .height = child_cross }
            else
                Box{ .x = content.x, .y = cursor, .width = child_cross, .height = child_main };
            try self.layoutNode(child_index, child_box, opacity);
            cursor += child_main + gap;
        }
    }

    fn layoutStack(self: *Lowerer, parent_index: usize, box: Box, opacity: f32) (LowerError || Allocator.Error)!void {
        const content = inset(box, self.snapshots[parent_index].properties.padding);
        for (self.snapshots, 0..) |child, child_index| {
            if (!isChild(child, self.snapshots[parent_index])) continue;
            var child_box = content;
            if (child.properties.width) |width| child_box.width = try dimension(width);
            if (child.properties.height) |height| child_box.height = try dimension(height);
            try self.layoutNode(child_index, child_box, opacity);
        }
    }

    fn intrinsic(self: *Lowerer, index: usize, axis: Axis) LowerError!f32 {
        const snapshot = self.snapshots[index];
        const properties = snapshot.properties;
        const explicit = if (axis == .horizontal) properties.width else properties.height;
        if (explicit) |value| return dimension(value);

        const before: f32 = @floatFromInt(if (axis == .horizontal) properties.padding.left else properties.padding.top);
        const after: f32 = @floatFromInt(if (axis == .horizontal) properties.padding.right else properties.padding.bottom);
        return switch (snapshot.kind) {
            .text => if (axis == .horizontal)
                before + after + @ceil(@as(f32, @floatFromInt(properties.text.len)) * try fontSize(properties.font_size) * 0.62)
            else
                before + after + try fontSize(properties.font_size),
            .icon, .shape, .polygon, .spacer => 0,
            .row, .column, .stack => blk: {
                var total: f32 = 0;
                var maximum: f32 = 0;
                var count: usize = 0;
                for (self.snapshots, 0..) |child, child_index| {
                    if (!isChild(child, snapshot)) continue;
                    const value = try self.intrinsic(child_index, axis);
                    total += value;
                    maximum = @max(maximum, value);
                    count += 1;
                }
                const flows_on_axis = (snapshot.kind == .row and axis == .horizontal) or
                    (snapshot.kind == .column and axis == .vertical);
                if (flows_on_axis and count > 1)
                    total += @as(f32, @floatFromInt(properties.gap)) * @as(f32, @floatFromInt(count - 1));
                break :blk before + after + if (flows_on_axis) total else maximum;
            },
        };
    }

    fn childCount(self: *const Lowerer, parent_index: usize) usize {
        var count: usize = 0;
        for (self.snapshots) |candidate| if (isChild(candidate, self.snapshots[parent_index])) {
            count += 1;
        };
        return count;
    }
};

pub fn lower(allocator: Allocator, snapshots: []const ui.NodeSnapshot, viewport: Viewport) (LowerError || Allocator.Error)!OwnedDrawList {
    try validateViewport(viewport);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var ops = std.ArrayList(DrawOp).empty;
    errdefer ops.deinit(allocator);
    var lowerer = Lowerer{ .allocator = allocator, .snapshots = snapshots, .arena = &arena, .ops = &ops };
    const root_box = Box{ .x = 0, .y = 0, .width = @floatFromInt(viewport.width), .height = @floatFromInt(viewport.height) };
    for (snapshots, 0..) |snapshot, index| if (snapshot.parent == null) {
        try lowerer.layoutNode(index, root_box, 1);
    };
    return .{ .allocator = allocator, .arena = arena, .ops = try ops.toOwnedSlice(allocator) };
}

fn isChild(candidate: ui.NodeSnapshot, parent: ui.NodeSnapshot) bool {
    return candidate.parent != null and candidate.parent.?.eql(parent.handle);
}

fn inset(box: Box, edges: ui.Edges) Box {
    const left: f32 = @floatFromInt(edges.left);
    const right: f32 = @floatFromInt(edges.right);
    const top: f32 = @floatFromInt(edges.top);
    const bottom: f32 = @floatFromInt(edges.bottom);
    return .{
        .x = box.x + left,
        .y = box.y + top,
        .width = @max(0, box.width - left - right),
        .height = @max(0, box.height - top - bottom),
    };
}

fn toRect(box: Box) graphics.skia.Rect {
    return .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
}

fn mainSize(box: Box, axis: Axis) f32 {
    return if (axis == .horizontal) box.width else box.height;
}

fn crossSize(box: Box, axis: Axis) f32 {
    return if (axis == .horizontal) box.height else box.width;
}

fn validateViewport(viewport: Viewport) LowerError!void {
    if (viewport.width == 0 or viewport.height == 0) return error.InvalidViewport;
}

fn validateSnapshot(snapshot: ui.NodeSnapshot) LowerError!void {
    const properties = snapshot.properties;
    if (!validColor(properties.fill) or !validColor(properties.text_color)) return error.InvalidColor;
    if (!std.math.isFinite(properties.opacity) or properties.opacity < 0 or properties.opacity > 1) return error.InvalidOpacity;
    if (!std.math.isFinite(properties.radius) or properties.radius < 0) return error.InvalidDimensions;
    if (snapshot.kind == .polygon and properties.points.len != 0) {
        ui.properties.validate(.polygon, .{ .points = properties.points }) catch return error.InvalidPolygon;
    }
}

fn dimension(value: u32) LowerError!f32 {
    if (value == 0) return error.InvalidDimensions;
    return @floatFromInt(value);
}

fn fontSize(value: u16) LowerError!f32 {
    if (value == 0) return error.InvalidFontSize;
    return @floatFromInt(value);
}

fn validColor(color: ui.Color) bool {
    return std.math.isFinite(color.r) and std.math.isFinite(color.g) and
        std.math.isFinite(color.b) and std.math.isFinite(color.a) and
        color.r >= 0 and color.r <= 1 and color.g >= 0 and color.g <= 1 and
        color.b >= 0 and color.b <= 1 and color.a >= 0 and color.a <= 1;
}

fn colorWithOpacity(color: ui.Color, opacity: f32) graphics.skia.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * opacity };
}

fn fixture(kind: ui.NodeKind, slot: u32, parent: ?ui.NodeHandle, properties: ui.NodeProperties) ui.NodeSnapshot {
    return .{ .handle = .{ .slot = slot, .generation = 1 }, .kind = kind, .parent = parent, .properties = properties, .dirty = .{} };
}

test "row layout preserves hierarchy, padding, and gap" {
    const root = ui.NodeHandle{ .slot = 0, .generation = 1 };
    const snapshots = [_]ui.NodeSnapshot{
        fixture(.row, 0, null, .{ .padding = .{ .top = 3, .right = 4, .bottom = 3, .left = 4 }, .gap = 5 }),
        fixture(.shape, 1, root, .{ .width = 20, .height = 10, .fill = ui.Color.rgba(1, 0, 0, 1) }),
        fixture(.text, 2, root, .{ .text = "hi", .font_size = 10 }),
    };
    var result = try lower(std.testing.allocator, &snapshots, .{ .width = 100, .height = 30 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.operationCount());
    try std.testing.expectEqual(@as(f32, 4), result.ops[0].rect.rect.x);
    try std.testing.expectEqual(@as(f32, 29), result.ops[1].text.x);
    try std.testing.expectEqual(@as(f32, 13), result.ops[1].text.baseline);
}

test "stack stretches auto-sized paint nodes to its box" {
    const root = ui.NodeHandle{ .slot = 0, .generation = 1 };
    const snapshots = [_]ui.NodeSnapshot{
        fixture(.stack, 0, null, .{ .width = 80, .height = 24 }),
        fixture(.shape, 1, root, .{ .fill = ui.Color.rgba(0, 1, 0, 1) }),
    };
    var result = try lower(std.testing.allocator, &snapshots, .{ .width = 100, .height = 30 });
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 80), result.ops[0].rect.rect.width);
    try std.testing.expectEqual(@as(f32, 24), result.ops[0].rect.rect.height);
}

test "polygon vertices are box-relative and may extend beyond layout bounds" {
    var points = ui.Polygon{ .len = 4 };
    points.points[0] = .{ .x = 0.25, .y = 0 };
    points.points[1] = .{ .x = 1.25, .y = 0 };
    points.points[2] = .{ .x = 1, .y = 1 };
    points.points[3] = .{ .x = 0, .y = 1 };
    const snapshot = fixture(.polygon, 0, null, .{
        .width = 80,
        .height = 20,
        .fill = ui.Color.rgba(0.2, 0.4, 0.6, 1),
        .points = points,
    });
    var result = try lower(std.testing.allocator, &.{snapshot}, .{ .width = 100, .height = 30 });
    defer result.deinit();
    const polygon = result.ops[0].polygon;
    try std.testing.expectEqual(@as(u8, 4), polygon.points.len);
    try std.testing.expectEqual(@as(f32, 20), polygon.points.points[0].x);
    try std.testing.expectEqual(@as(f32, 100), polygon.points.points[1].x);
    try std.testing.expectEqual(@as(f32, 20), polygon.points.points[3].y);
}

test "icon nodes lower to a renderer-neutral image operation" {
    const snapshot = fixture(.icon, 0, null, .{
        .width = 24,
        .height = 20,
        .padding = .{ .top = 2, .right = 3, .bottom = 2, .left = 3 },
        .icon_source = "/icons/example.svg",
        .opacity = 0.75,
    });
    var result = try lower(std.testing.allocator, &.{snapshot}, .{ .width = 100, .height = 30 });
    defer result.deinit();
    const icon = result.ops[0].icon;
    try std.testing.expectEqualStrings("/icons/example.svg", icon.source);
    try std.testing.expectEqual(@as(f32, 3), icon.rect.x);
    try std.testing.expectEqual(@as(f32, 2), icon.rect.y);
    try std.testing.expectEqual(@as(f32, 18), icon.rect.width);
    try std.testing.expectEqual(@as(f32, 16), icon.rect.height);
    try std.testing.expectEqual(@as(f32, 0.75), icon.opacity);
}

test "flows stretch auto-sized children across their box" {
    const root = ui.NodeHandle{ .slot = 0, .generation = 1 };
    const snapshots = [_]ui.NodeSnapshot{
        fixture(.column, 0, null, .{}),
        fixture(.shape, 1, root, .{ .height = 10, .fill = ui.Color.rgba(0, 1, 0, 1) }),
    };
    var result = try lower(std.testing.allocator, &snapshots, .{ .width = 100, .height = 30 });
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 100), result.ops[0].rect.rect.width);
    try std.testing.expectEqual(@as(f32, 10), result.ops[0].rect.rect.height);
}

test "lower rejects unusable input" {
    try std.testing.expectError(error.InvalidViewport, lower(std.testing.allocator, &.{}, .{ .width = 0, .height = 1 }));
    const bad = fixture(.text, 0, null, .{ .text = "x", .font_size = 0 });
    try std.testing.expectError(error.InvalidFontSize, lower(std.testing.allocator, &.{bad}, .{ .width = 1, .height = 1 }));
}

test "clip and horizontal offset bound translated descendants" {
    const root = ui.NodeHandle{ .slot = 0, .generation = 1 };
    const content = ui.NodeHandle{ .slot = 1, .generation = 1 };
    const snapshots = [_]ui.NodeSnapshot{
        fixture(.stack, 0, null, .{ .width = 40, .height = 20, .clip = true }),
        fixture(.row, 1, root, .{ .width = 80, .offset_x = -12.5 }),
        fixture(.shape, 2, content, .{ .width = 20, .fill = ui.Color.white }),
    };
    var result = try lower(std.testing.allocator, &snapshots, .{ .width = 100, .height = 30 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.operationCount());
    try std.testing.expectEqual(@as(f32, 40), result.ops[0].push_clip.width);
    try std.testing.expectEqual(@as(f32, -12.5), result.ops[1].rect.rect.x);
    try std.testing.expect(result.ops[2] == .pop_clip);
}
