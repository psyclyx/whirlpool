//! Retained-node property values, ownership, validation, and invalidation.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const NodeKind = enum {
    row,
    column,
    stack,
    spacer,
    shape,
    polygon,
    text,
    icon,
};

pub const max_polygon_points = 16;
pub const max_polygon_coordinate: f32 = 4096;

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Box-relative vertices for a filled polygon. Coordinates are normalized
/// independently against width and height, and may extend outside 0...1 so
/// adjacent shapes can share an edge without changing layout geometry.
pub const Polygon = struct {
    points: [max_polygon_points]Point = [_]Point{.{}} ** max_polygon_points,
    len: u8 = 0,

    pub fn slice(self: *const Polygon) []const Point {
        return self.points[0..self.len];
    }
};

pub const Edges = struct {
    top: u32 = 0,
    right: u32 = 0,
    bottom: u32 = 0,
    left: u32 = 0,
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const DirtyFlags = packed struct(u2) {
    layout: bool = false,
    paint: bool = false,
};

pub const Snapshot = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    gap: u32 = 0,
    padding: Edges = .{},
    flex: u32 = 0,
    fill: Color = Color.transparent,
    radius: f32 = 0,
    points: Polygon = .{},
    text: []const u8 = &.{},
    icon_source: []const u8 = &.{},
    text_color: Color = Color.white,
    font_size: u16 = 16,
    opacity: f32 = 1,
    clip: bool = false,
    offset_x: f32 = 0,
};

pub const Value = union(enum) {
    width: ?u32,
    height: ?u32,
    gap: u32,
    padding: Edges,
    flex: u32,
    fill: Color,
    radius: f32,
    points: Polygon,
    text: []const u8,
    icon_source: []const u8,
    text_color: Color,
    font_size: u16,
    opacity: f32,
    clip: bool,
    offset_x: f32,
};

pub const Error = error{
    PropertyNotSupported,
    InvalidValue,
};

pub const Metadata = struct {
    supported_by: enum { every_node, paint, shape, polygon, text, icon },
    dirty: DirtyFlags,
    owns_bytes: bool = false,
};

const layout_and_paint = DirtyFlags{ .layout = true, .paint = true };
const paint = DirtyFlags{ .paint = true };

/// The single explicit schema for applicability, invalidation, and ownership.
/// Keeping this as ordinary Zig data makes additions visible in review and
/// avoids reflection-driven behavior.
pub fn metadata(value: Value) Metadata {
    return switch (value) {
        .width, .height, .gap, .padding, .flex, .offset_x => .{ .supported_by = .every_node, .dirty = layout_and_paint },
        .fill => .{ .supported_by = .paint, .dirty = paint },
        .radius => .{ .supported_by = .shape, .dirty = paint },
        .points => .{ .supported_by = .polygon, .dirty = paint },
        .text => .{ .supported_by = .text, .dirty = layout_and_paint, .owns_bytes = true },
        .icon_source => .{ .supported_by = .icon, .dirty = paint, .owns_bytes = true },
        .text_color, .font_size => .{ .supported_by = .text, .dirty = paint },
        .opacity, .clip => .{ .supported_by = .every_node, .dirty = paint },
    };
}

pub fn validate(kind: NodeKind, value: Value) Error!void {
    const schema = metadata(value);
    switch (schema.supported_by) {
        .every_node => {},
        .paint => if (kind != .shape and kind != .polygon) return error.PropertyNotSupported,
        .shape => if (kind != .shape) return error.PropertyNotSupported,
        .polygon => if (kind != .polygon) return error.PropertyNotSupported,
        .text => if (kind != .text) return error.PropertyNotSupported,
        .icon => if (kind != .icon) return error.PropertyNotSupported,
    }

    switch (value) {
        .fill => |color| if (!validColor(color)) return error.InvalidValue,
        .text_color => |color| if (!validColor(color)) return error.InvalidValue,
        .radius => |radius| if (!std.math.isFinite(radius) or radius < 0) return error.InvalidValue,
        .points => |polygon| {
            if (polygon.len < 3 or polygon.len > max_polygon_points) return error.InvalidValue;
            for (polygon.slice()) |point| {
                if (!validCoordinate(point.x) or !validCoordinate(point.y)) return error.InvalidValue;
            }
        },
        .opacity => |opacity| if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidValue,
        else => {},
    }
}

fn validCoordinate(value: f32) bool {
    return std.math.isFinite(value) and @abs(value) <= max_polygon_coordinate;
}

pub fn validColor(color: Color) bool {
    return std.math.isFinite(color.r) and std.math.isFinite(color.g) and
        std.math.isFinite(color.b) and std.math.isFinite(color.a) and
        color.r >= 0 and color.r <= 1 and color.g >= 0 and color.g <= 1 and
        color.b >= 0 and color.b <= 1 and color.a >= 0 and color.a <= 1;
}

pub fn cloneValue(allocator: Allocator, value: Value) !Value {
    return switch (value) {
        .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
        .icon_source => |bytes| .{ .icon_source = try allocator.dupe(u8, bytes) },
        else => value,
    };
}

pub fn freeValue(allocator: Allocator, value: Value) void {
    switch (value) {
        .text, .icon_source => |bytes| if (bytes.len != 0) allocator.free(bytes),
        else => {},
    }
}

pub const Owned = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    gap: u32 = 0,
    padding: Edges = .{},
    flex: u32 = 0,
    fill: Color = Color.transparent,
    radius: f32 = 0,
    points: Polygon = .{},
    text: []u8 = &.{},
    icon_source: []u8 = &.{},
    text_color: Color = Color.white,
    font_size: u16 = 16,
    opacity: f32 = 1,
    clip: bool = false,
    offset_x: f32 = 0,

    pub fn snapshot(self: Owned) Snapshot {
        return .{
            .width = self.width,
            .height = self.height,
            .gap = self.gap,
            .padding = self.padding,
            .flex = self.flex,
            .fill = self.fill,
            .radius = self.radius,
            .points = self.points,
            .text = self.text,
            .icon_source = self.icon_source,
            .text_color = self.text_color,
            .font_size = self.font_size,
            .opacity = self.opacity,
            .clip = self.clip,
            .offset_x = self.offset_x,
        };
    }

    pub fn commit(self: *Owned, allocator: Allocator, value: Value, owned_bytes: ?[]u8) void {
        switch (value) {
            .width => |item| self.width = item,
            .height => |item| self.height = item,
            .gap => |item| self.gap = item,
            .padding => |item| self.padding = item,
            .flex => |item| self.flex = item,
            .fill => |item| self.fill = item,
            .radius => |item| self.radius = item,
            .points => |item| self.points = item,
            .text => {
                const replacement = owned_bytes orelse {
                    std.debug.assert(std.mem.eql(u8, self.text, value.text));
                    return;
                };
                if (self.text.len != 0) allocator.free(self.text);
                self.text = replacement;
            },
            .icon_source => {
                const replacement = owned_bytes orelse {
                    std.debug.assert(std.mem.eql(u8, self.icon_source, value.icon_source));
                    return;
                };
                if (self.icon_source.len != 0) allocator.free(self.icon_source);
                self.icon_source = replacement;
            },
            .text_color => |item| self.text_color = item,
            .font_size => |item| self.font_size = item,
            .opacity => |item| self.opacity = item,
            .clip => |item| self.clip = item,
            .offset_x => |item| self.offset_x = item,
        }
    }
};

test "property metadata is the shared applicability and invalidation schema" {
    try std.testing.expectError(error.PropertyNotSupported, validate(.text, .{ .fill = Color.white }));
    try std.testing.expect(metadata(.{ .text = "value" }).owns_bytes);
    try std.testing.expect(metadata(.{ .text = "value" }).dirty.layout);
    try std.testing.expect(metadata(.{ .icon_source = "icon.svg" }).owns_bytes);
    try std.testing.expect(!metadata(.{ .icon_source = "icon.svg" }).dirty.layout);
    try std.testing.expect(!metadata(.{ .opacity = 1 }).dirty.layout);
}

test "polygon points are finite, bounded in count, and owned inline" {
    var polygon = Polygon{ .len = 3 };
    polygon.points[0] = .{ .x = -0.25, .y = 0 };
    polygon.points[1] = .{ .x = 1.25, .y = 0 };
    polygon.points[2] = .{ .x = 0.5, .y = 1 };
    try validate(.polygon, .{ .points = polygon });
    try std.testing.expectError(error.PropertyNotSupported, validate(.shape, .{ .points = polygon }));
    polygon.points[1].x = std.math.inf(f32);
    try std.testing.expectError(error.InvalidValue, validate(.polygon, .{ .points = polygon }));
    polygon.points[1].x = max_polygon_coordinate + 1;
    try std.testing.expectError(error.InvalidValue, validate(.polygon, .{ .points = polygon }));
}
