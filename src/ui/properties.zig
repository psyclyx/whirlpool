//! Retained-node property values, ownership, validation, and invalidation.
//!
//! Every property is one field of `Fields` and one same-named tag of `Value`;
//! `metadata` is the single schema saying which nodes accept it and whether it
//! changes geometry (layout) or only appearance (paint).

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
pub const max_polygon_coordinate: f32 = 65536;

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Pixels added after scaling, so a vertex can sit a fixed distance from a
    /// box edge whatever the box's size (a slanted edge, say).
    dx: f32 = 0,
    dy: f32 = 0,
};

/// Box-relative vertices for a filled polygon: each is at (x * width + dx,
/// y * height + dy) from the box origin. Points may lie outside the box, so
/// adjacent shapes can share an edge without changing layout geometry.
pub const Polygon = struct {
    points: [max_polygon_points]Point = [_]Point{.{}} ** max_polygon_points,
    len: u8 = 0,

    pub fn slice(self: *const Polygon) []const Point {
        return self.points[0..self.len];
    }
};

pub const max_gradient_stops = 64;

/// A polygon's linear gradient, as the bytes a node stores it in (owned like
/// text, so a node without one carries only an empty slice): little-endian
/// f32s, `slant` and then `x, r, g, b, a` per stop. A stop's `x` is pixels
/// from the box's left edge along its bottom edge; colour is a function of
/// `x - slant * (bottom - y)`, so isolines lean like the angled panels.
/// Stops are in increasing `x`; colours clamp beyond the first and last.
pub const Gradient = struct {
    bytes: []const u8,

    pub const header_bytes = 4;
    pub const stop_bytes = 20;

    pub const Stop = struct { x: f32, color: Color };

    pub fn encodedLength(stop_count: usize) usize {
        return if (stop_count == 0) 0 else header_bytes + stop_count * stop_bytes;
    }

    /// Write the slant (`lean`) and `stops` into `buffer` (at least
    /// `encodedLength`).
    pub fn encode(buffer: []u8, lean: f32, stops: []const Stop) []u8 {
        if (stops.len == 0) return buffer[0..0];
        writeFloat(buffer[0..4], lean);
        for (stops, 0..) |item, index| {
            const at = header_bytes + index * stop_bytes;
            const values = [5]f32{ item.x, item.color.r, item.color.g, item.color.b, item.color.a };
            for (values, 0..) |value, offset| writeFloat(buffer[at + offset * 4 ..][0..4], value);
        }
        return buffer[0..encodedLength(stops.len)];
    }

    pub fn len(self: Gradient) usize {
        if (self.bytes.len < header_bytes) return 0;
        return (self.bytes.len - header_bytes) / stop_bytes;
    }

    pub fn slant(self: Gradient) f32 {
        return readFloat(self.bytes[0..4]);
    }

    pub fn stop(self: Gradient, index: usize) Stop {
        const at = header_bytes + index * stop_bytes;
        return .{ .x = readFloat(self.bytes[at..][0..4]), .color = .{
            .r = readFloat(self.bytes[at + 4 ..][0..4]),
            .g = readFloat(self.bytes[at + 8 ..][0..4]),
            .b = readFloat(self.bytes[at + 12 ..][0..4]),
            .a = readFloat(self.bytes[at + 16 ..][0..4]),
        } };
    }

    /// Whether `bytes` encode a gradient a renderer can draw: empty (none), or
    /// 1..max stops, finite, in increasing `x`, with valid colours.
    pub fn valid(bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        if (bytes.len < header_bytes + stop_bytes or (bytes.len - header_bytes) % stop_bytes != 0) return false;
        const gradient = Gradient{ .bytes = bytes };
        if (gradient.len() > max_gradient_stops) return false;
        if (!std.math.isFinite(gradient.slant()) or @abs(gradient.slant()) > 16) return false;
        var previous = -std.math.inf(f32);
        for (0..gradient.len()) |index| {
            const item = gradient.stop(index);
            if (!validCoordinate(item.x) or item.x < previous or !validColor(item.color)) return false;
            previous = item.x;
        }
        return true;
    }

    fn readFloat(bytes: *const [4]u8) f32 {
        return @bitCast(std.mem.readInt(u32, bytes, .little));
    }

    fn writeFloat(bytes: *[4]u8, value: f32) void {
        std.mem.writeInt(u32, bytes, @bitCast(value), .little);
    }
};

pub const TextAlign = enum { start, center, end };
pub const TextVAlign = enum { top, middle };
/// Where children sit across a row or column (or within a stack, on both
/// axes) when they are smaller than it. `stretch` fills the space.
pub const Align = enum { stretch, start, center, end };
/// How a row or column places its children along its axis when they do not
/// fill it (nothing flexes).
pub const Justify = enum { start, center, end, between };
/// What a text node does with text wider than its box.
pub const TextOverflow = enum { clip, ellipsis };

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

fn Fields(comptime Bytes: type) type {
    return struct {
        // Geometry.
        visible: bool = true,
        width: ?u32 = null,
        height: ?u32 = null,
        min_width: u32 = 0,
        max_width: ?u32 = null,
        min_height: u32 = 0,
        max_height: ?u32 = null,
        gap: u32 = 0,
        padding: Edges = .{},
        flex: u32 = 0,
        shrink: u32 = 0,
        @"align": Align = .stretch,
        justify: Justify = .start,
        // Appearance. Offsets move a node (and its subtree) after layout, so
        // scrolling and sliding never re-run layout.
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        opacity: f32 = 1,
        clip: bool = false,
        /// With `clip`, the region drawing is confined to: these points (as for
        /// a polygon) when there are any, else the node's box.
        clip_shape: Polygon = .{},
        fill: Color = Color.transparent,
        /// For a shape: the colour at its centre, `fill` being the colour at
        /// its corners, with a radial gradient between that follows the
        /// shape's proportions. Null for a flat `fill`.
        fill_center: ?Color = null,
        radius: f32 = 0,
        points: Polygon = .{},
        /// For a polygon: a linear gradient instead of `fill`, encoded as
        /// `Gradient` describes; empty for a flat `fill`.
        gradient: Bytes = &.{},
        text: Bytes = &.{},
        icon_source: Bytes = &.{},
        text_color: Color = Color.white,
        font_size: u16 = 16,
        /// A font family name; empty for the renderer's default.
        font_family: Bytes = &.{},
        text_align: TextAlign = .start,
        text_valign: TextVAlign = .top,
        text_overflow: TextOverflow = .clip,
    };
}

/// The properties holding bytes (strings, an encoded gradient), which a node
/// owns copies of.
pub const string_fields = .{ "text", "icon_source", "font_family", "gradient" };

pub const Snapshot = Fields([]const u8);
/// The same fields as a node stores them, owning their bytes.
pub const Stored = Fields([]u8);

pub const Value = union(enum) {
    visible: bool,
    width: ?u32,
    height: ?u32,
    min_width: u32,
    max_width: ?u32,
    min_height: u32,
    max_height: ?u32,
    gap: u32,
    padding: Edges,
    flex: u32,
    shrink: u32,
    @"align": Align,
    justify: Justify,
    offset_x: f32,
    offset_y: f32,
    opacity: f32,
    clip: bool,
    clip_shape: Polygon,
    fill: Color,
    fill_center: ?Color,
    radius: f32,
    points: Polygon,
    gradient: []const u8,
    text: []const u8,
    icon_source: []const u8,
    text_color: Color,
    font_size: u16,
    font_family: []const u8,
    text_align: TextAlign,
    text_valign: TextVAlign,
    text_overflow: TextOverflow,
};

comptime {
    // `Value` and `Fields` must name the same properties.
    const fields = @typeInfo(Snapshot).@"struct".fields;
    const tags = @typeInfo(Value).@"union".fields;
    std.debug.assert(fields.len == tags.len);
    for (tags) |tag| std.debug.assert(@hasField(Snapshot, tag.name));
}

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
pub fn metadata(value: Value) Metadata {
    return switch (value) {
        .visible, .width, .height, .min_width, .max_width, .min_height, .max_height => .{ .supported_by = .every_node, .dirty = layout_and_paint },
        .gap, .padding, .flex, .shrink, .@"align", .justify => .{ .supported_by = .every_node, .dirty = layout_and_paint },
        .offset_x, .offset_y, .opacity, .clip, .clip_shape => .{ .supported_by = .every_node, .dirty = paint },
        .fill => .{ .supported_by = .paint, .dirty = paint },
        .fill_center, .radius => .{ .supported_by = .shape, .dirty = paint },
        .points => .{ .supported_by = .polygon, .dirty = paint },
        .gradient => .{ .supported_by = .polygon, .dirty = paint, .owns_bytes = true },
        .text => .{ .supported_by = .text, .dirty = layout_and_paint, .owns_bytes = true },
        .font_size => .{ .supported_by = .text, .dirty = layout_and_paint },
        .font_family => .{ .supported_by = .text, .dirty = layout_and_paint, .owns_bytes = true },
        .icon_source => .{ .supported_by = .icon, .dirty = paint, .owns_bytes = true },
        .text_color, .text_align, .text_valign, .text_overflow => .{ .supported_by = .text, .dirty = paint },
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
        .fill, .text_color => |color| if (!validColor(color)) return error.InvalidValue,
        .fill_center => |center| if (center) |color| if (!validColor(color)) return error.InvalidValue,
        .radius => |radius| if (!std.math.isFinite(radius) or radius < 0) return error.InvalidValue,
        .offset_x, .offset_y => |offset| if (!std.math.isFinite(offset)) return error.InvalidValue,
        .points, .clip_shape => |polygon| {
            if (polygon.len > max_polygon_points) return error.InvalidValue;
            if (polygon.len < 3 and !(value == .clip_shape and polygon.len == 0)) return error.InvalidValue;
            for (polygon.slice()) |point| {
                if (!validCoordinate(point.x) or !validCoordinate(point.y) or !validCoordinate(point.dx) or !validCoordinate(point.dy)) return error.InvalidValue;
            }
        },
        .opacity => |opacity| if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidValue,
        .gradient => |bytes| if (!Gradient.valid(bytes)) return error.InvalidValue,
        .font_size => |size| if (size == 0) return error.InvalidValue,
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
        .font_family => |bytes| .{ .font_family = try allocator.dupe(u8, bytes) },
        .gradient => |bytes| .{ .gradient = try allocator.dupe(u8, bytes) },
        else => value,
    };
}

pub fn freeValue(allocator: Allocator, value: Value) void {
    switch (value) {
        .text, .icon_source, .font_family, .gradient => |bytes| if (bytes.len != 0) allocator.free(bytes),
        else => {},
    }
}

pub const Owned = struct {
    fields: Stored = .{},

    pub fn snapshot(self: *const Owned) Snapshot {
        var result: Snapshot = undefined;
        inline for (@typeInfo(Snapshot).@"struct".fields) |field|
            @field(result, field.name) = @field(self.fields, field.name);
        return result;
    }

    pub fn commit(self: *Owned, allocator: Allocator, value: Value, owned_bytes: ?[]u8) void {
        switch (value) {
            inline .text, .icon_source, .font_family, .gradient => |requested, tag| {
                const slot = &@field(self.fields, @tagName(tag));
                const replacement = owned_bytes orelse {
                    std.debug.assert(std.mem.eql(u8, slot.*, requested));
                    return;
                };
                if (slot.len != 0) allocator.free(slot.*);
                slot.* = replacement;
            },
            inline else => |item, tag| @field(self.fields, @tagName(tag)) = item,
        }
    }

    pub fn freeBytes(self: *Owned, allocator: Allocator) void {
        inline for (string_fields) |name| {
            const bytes = @field(self.fields, name);
            if (bytes.len != 0) allocator.free(bytes);
            @field(self.fields, name) = &.{};
        }
    }
};

/// Whether setting `value` would leave the node exactly as it is. Programs set
/// properties freely (a value recomputed each update is usually the same), so
/// scenes skip these instead of marking the node dirty and re-rendering.
/// `current` is a node's fields, stored or snapshotted, by value or pointer.
pub fn matches(current: anytype, value: Value) bool {
    return switch (value) {
        inline .text, .icon_source, .font_family, .gradient => |item, tag| std.mem.eql(u8, @field(current, @tagName(tag)), item),
        inline .points, .clip_shape => |item, tag| samePoints(@field(current, @tagName(tag)), item),
        inline else => |item, tag| std.meta.eql(@field(current, @tagName(tag)), item),
    };
}

fn samePoints(a: Polygon, b: Polygon) bool {
    if (a.len != b.len) return false;
    for (a.slice(), b.slice()) |left, right| {
        if (left.x != right.x or left.y != right.y or left.dx != right.dx or left.dy != right.dy) return false;
    }
    return true;
}

test "property metadata is the shared applicability and invalidation schema" {
    try std.testing.expectError(error.PropertyNotSupported, validate(.text, .{ .fill = Color.white }));
    try std.testing.expect(metadata(.{ .text = "value" }).owns_bytes);
    try std.testing.expect(metadata(.{ .text = "value" }).dirty.layout);
    try std.testing.expect(metadata(.{ .icon_source = "icon.svg" }).owns_bytes);
    try std.testing.expect(!metadata(.{ .icon_source = "icon.svg" }).dirty.layout);
    try std.testing.expect(!metadata(.{ .opacity = 1 }).dirty.layout);
    // Moving a node is paint-only: scrolling must not re-run layout.
    try std.testing.expect(!metadata(.{ .offset_x = 3 }).dirty.layout);
    try std.testing.expect(metadata(.{ .visible = false }).dirty.layout);
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

test "setting a property to its current value is recognised as a no-op" {
    var snapshot = Snapshot{};
    try std.testing.expect(matches(snapshot, .{ .opacity = 1 }));
    try std.testing.expect(!matches(snapshot, .{ .opacity = 0.5 }));
    try std.testing.expect(matches(snapshot, .{ .fill = Color.transparent }));
    try std.testing.expect(!matches(snapshot, .{ .fill = Color.white }));
    try std.testing.expect(matches(snapshot, .{ .width = null }));
    try std.testing.expect(!matches(snapshot, .{ .width = 10 }));
    try std.testing.expect(matches(snapshot, .{ .visible = true }));
    try std.testing.expect(!matches(snapshot, .{ .@"align" = .center }));
    snapshot.points = .{ .len = 3 };
    try std.testing.expect(matches(snapshot, .{ .points = .{ .len = 3 } }));
    try std.testing.expect(!matches(snapshot, .{ .points = .{ .len = 4 } }));
    try std.testing.expect(matches(snapshot, .{ .text = "" }));
    try std.testing.expect(!matches(snapshot, .{ .text = "x" }));
}

test "committing a value stores it under the same-named field" {
    var owned = Owned{};
    owned.commit(std.testing.allocator, .{ .justify = .between }, null);
    owned.commit(std.testing.allocator, .{ .max_width = 120 }, null);
    owned.commit(std.testing.allocator, .{ .text = "hi" }, try std.testing.allocator.dupe(u8, "hi"));
    defer owned.freeBytes(std.testing.allocator);
    const snapshot = owned.snapshot();
    try std.testing.expectEqual(Justify.between, snapshot.justify);
    try std.testing.expectEqual(@as(?u32, 120), snapshot.max_width);
    try std.testing.expectEqualStrings("hi", snapshot.text);
}

test "a gradient round-trips through its encoding and is validated" {
    var buffer: [Gradient.encodedLength(2)]u8 = undefined;
    const stops = [_]Gradient.Stop{
        .{ .x = 0, .color = .{ .r = 1, .g = 0, .b = 0 } },
        .{ .x = 40, .color = .{ .r = 0, .g = 0, .b = 1, .a = 0.5 } },
    };
    const bytes = Gradient.encode(&buffer, 0.3, &stops);
    const gradient = Gradient{ .bytes = bytes };
    try std.testing.expectEqual(@as(usize, 2), gradient.len());
    try std.testing.expectEqual(@as(f32, 0.3), gradient.slant());
    try std.testing.expectEqual(stops[1].x, gradient.stop(1).x);
    try std.testing.expectEqual(stops[1].color, gradient.stop(1).color);
    try validate(.polygon, .{ .gradient = bytes });
    try validate(.polygon, .{ .gradient = &.{} });
    try std.testing.expectError(error.PropertyNotSupported, validate(.shape, .{ .gradient = bytes }));
    try std.testing.expect(!metadata(.{ .gradient = bytes }).dirty.layout);
    try std.testing.expect(metadata(.{ .gradient = bytes }).owns_bytes);
    // Out of order, or a truncated stop, is not a gradient.
    const backwards = [_]Gradient.Stop{ stops[1], stops[0] };
    try std.testing.expectError(error.InvalidValue, validate(.polygon, .{ .gradient = Gradient.encode(&buffer, 0, &backwards) }));
    try std.testing.expectError(error.InvalidValue, validate(.polygon, .{ .gradient = bytes[0 .. bytes.len - 1] }));
}
