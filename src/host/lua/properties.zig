//! Translation of script property values into retained UI mutations.
//!
//! A Lua property name is the retained property of the same name (see
//! `ui.properties`), decoded by that property's type, so a property added to
//! the schema is settable from Lua with no change here. A few aliases remain
//! for convenience: `name` (text), `size` (font_size), and `color` (fill, or
//! text_color on text).

const std = @import("std");
const script = @import("whirlpool-script");
const ui = @import("whirlpool-ui");

const lua_program = script.program_loader;

/// Decode and stage one named property on a live retained node.
pub fn apply(composition: anytype, id: lua_program.NodeId, key: []const u8, value: lua_program.Value) !void {
    if (!composition.in_batch) return error.InvalidBatch;
    if (id == 0 or id >= composition.nodes.items.len) return error.StaleNode;
    const handle = composition.nodes.items[id] orelse return error.StaleNode;
    const node = composition.scene.get(handle) orelse return error.StaleNode;

    const name = resolve(key, node.kind);
    inline for (@typeInfo(ui.PropertyValue).@"union".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            const decoded = try decode(field.type, value);
            try composition.delta.set(handle, @unionInit(ui.PropertyValue, field.name, decoded));
            composition.stats.applied_properties += 1;
            return;
        }
    }
    return error.InvalidProperty;
}

fn resolve(key: []const u8, kind: ui.NodeKind) []const u8 {
    if (std.mem.eql(u8, key, "name")) return "text";
    if (std.mem.eql(u8, key, "size")) return "font_size";
    if (std.mem.eql(u8, key, "color")) return if (kind == .text) "text_color" else "fill";
    return key;
}

fn decode(comptime T: type, value: lua_program.Value) !T {
    if (T == bool) return switch (value) {
        .boolean => |item| item,
        else => error.InvalidProperty,
    };
    if (T == ?u32) return switch (value) {
        .nil => null,
        else => try integer(u32, value),
    };
    if (T == u32 or T == u16) return integer(T, value);
    if (T == f32) return number(value);
    if (T == []const u8) return switch (value) {
        .string => |item| item,
        else => error.InvalidProperty,
    };
    if (T == ui.Edges) return edges(value);
    if (T == ui.Color) return color(value);
    if (T == ui.Polygon) return polygon(value);
    if (@typeInfo(T) == .@"enum") return switch (value) {
        .string => |item| std.meta.stringToEnum(T, item) orelse error.InvalidProperty,
        else => error.InvalidProperty,
    };
    @compileError("no Lua decoding for property type " ++ @typeName(T));
}

fn number(value: lua_program.Value) !f32 {
    return switch (value) {
        .number => |item| if (std.math.isFinite(item) and @abs(item) <= std.math.maxInt(i32))
            @floatCast(item)
        else
            error.InvalidProperty,
        else => error.InvalidProperty,
    };
}

fn integer(comptime T: type, value: lua_program.Value) !T {
    const item = switch (value) {
        .number => |item| item,
        else => return error.InvalidProperty,
    };
    if (!std.math.isFinite(item) or item < 0 or @floor(item) != item or item > std.math.maxInt(T))
        return error.InvalidProperty;
    return @intFromFloat(item);
}

/// `{ top, right, bottom, left }`, or one number for all four sides.
fn edges(value: lua_program.Value) !ui.Edges {
    if (value == .number) {
        const all = try integer(u32, value);
        return .{ .top = all, .right = all, .bottom = all, .left = all };
    }
    const values = array(value, 4) orelse return error.InvalidProperty;
    return .{
        .top = try integer(u32, values[0]),
        .right = try integer(u32, values[1]),
        .bottom = try integer(u32, values[2]),
        .left = try integer(u32, values[3]),
    };
}

fn color(value: lua_program.Value) !ui.Color {
    const values = array(value, 3) orelse return error.InvalidProperty;
    const result = ui.Color{
        .r = try number(values[0]),
        .g = try number(values[1]),
        .b = try number(values[2]),
        .a = if (values.len >= 4) try number(values[3]) else 1,
    };
    if (!ui.properties.validColor(result)) return error.InvalidProperty;
    return result;
}

fn polygon(value: lua_program.Value) !ui.Polygon {
    const values = array(value, 3) orelse return error.InvalidProperty;
    if (values.len > ui.properties.max_polygon_points) return error.InvalidProperty;
    var result = ui.Polygon{ .len = @intCast(values.len) };
    for (values, 0..) |item, index| {
        // { x, y } or { x, y, dx, dy }.
        const coordinates = array(item, 2) orelse return error.InvalidProperty;
        if (coordinates.len != 2 and coordinates.len != 4) return error.InvalidProperty;
        result.points[index] = .{ .x = try number(coordinates[0]), .y = try number(coordinates[1]) };
        if (coordinates.len == 4) {
            result.points[index].dx = try number(coordinates[2]);
            result.points[index].dy = try number(coordinates[3]);
        }
    }
    return result;
}

fn array(value: lua_program.Value, minimum: usize) ?[]const lua_program.Value {
    return switch (value) {
        .array => |items| if (items.len >= minimum) items else null,
        else => null,
    };
}

test "every retained property decodes from its Lua form" {
    try std.testing.expectEqual(@as(?u32, null), try decode(?u32, .nil));
    try std.testing.expectEqual(@as(?u32, 12), try decode(?u32, .{ .number = 12 }));
    try std.testing.expectError(error.InvalidProperty, decode(u32, .{ .number = 1.5 }));
    try std.testing.expectEqual(ui.Align.center, try decode(ui.Align, .{ .string = "center" }));
    try std.testing.expectError(error.InvalidProperty, decode(ui.Justify, .{ .string = "sideways" }));
    try std.testing.expectEqual(ui.Edges{ .top = 3, .right = 3, .bottom = 3, .left = 3 }, try decode(ui.Edges, .{ .number = 3 }));
    try std.testing.expectEqual(@as(f32, -4), try decode(f32, .{ .number = -4 }));
    try std.testing.expectError(error.InvalidProperty, decode(ui.Color, .{ .array = &.{ .{ .number = 2 }, .{ .number = 0 }, .{ .number = 0 } } }));
}
