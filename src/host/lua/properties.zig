//! Translation of script property values into retained UI mutations.

const std = @import("std");
const script = @import("whirlpool-script");
const ui = @import("whirlpool-ui");

const lua_program = script.program_loader;

/// Decode and stage one named property on a live retained node.
pub fn apply(composition: anytype, id: lua_program.NodeId, key: []const u8, value: lua_program.Value) !void {
    if (!composition.in_batch) return error.InvalidBatch;
    if (id == 0 or id >= composition.nodes.items.len) return error.StaleNode;
    const handle = composition.nodes.items[id] orelse return error.StaleNode;
    const snapshot = composition.scene.node(handle) orelse return error.StaleNode;

    if (std.mem.eql(u8, key, "text") or std.mem.eql(u8, key, "name")) {
        try setText(composition, handle, value);
    } else if (std.mem.eql(u8, key, "width")) {
        try setU32(composition, handle, value, .width);
    } else if (std.mem.eql(u8, key, "height")) {
        try setU32(composition, handle, value, .height);
    } else if (std.mem.eql(u8, key, "gap")) {
        try setU32(composition, handle, value, .gap);
    } else if (std.mem.eql(u8, key, "flex")) {
        try setU32(composition, handle, value, .flex);
    } else if (std.mem.eql(u8, key, "font_size") or std.mem.eql(u8, key, "size")) {
        try setFontSize(composition, handle, value);
    } else if (std.mem.eql(u8, key, "opacity")) {
        try setOpacity(composition, handle, value);
    } else if (std.mem.eql(u8, key, "clip")) {
        try setClip(composition, handle, value);
    } else if (std.mem.eql(u8, key, "offset_x")) {
        try setOffsetX(composition, handle, value);
    } else if (std.mem.eql(u8, key, "padding")) {
        try setPadding(composition, handle, value);
    } else if (std.mem.eql(u8, key, "radius")) {
        try setRadius(composition, handle, value);
    } else if (std.mem.eql(u8, key, "fill") or std.mem.eql(u8, key, "color")) {
        try setColor(composition, snapshot.kind, handle, value);
    } else if (std.mem.eql(u8, key, "text_color")) {
        try setTextColor(composition, handle, value);
    } else {
        return error.InvalidProperty;
    }
    std.debug.assert(composition.stats.applied_properties > 0);
}

const U32Property = enum { width, height, gap, flex };

fn setText(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value) !void {
    switch (value) {
        .string => |text| try composition.delta.setText(handle, text),
        else => return error.InvalidProperty,
    }
    composition.stats.applied_properties += 1;
}

fn setU32(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value, property: U32Property) !void {
    const number = try integerValue(value);
    if (number > std.math.maxInt(u32)) return error.InvalidProperty;
    const converted: u32 = @intCast(number);
    switch (property) {
        .width => try composition.delta.setWidth(handle, converted),
        .height => try composition.delta.setHeight(handle, converted),
        .gap => try composition.delta.setGap(handle, converted),
        .flex => try composition.delta.setFlex(handle, converted),
    }
    composition.stats.applied_properties += 1;
}

fn setFontSize(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value) !void {
    const number = try integerValue(value);
    if (number == 0 or number > std.math.maxInt(u16)) return error.InvalidProperty;
    try composition.delta.setFontSize(handle, @intCast(number));
    composition.stats.applied_properties += 1;
}

fn setOpacity(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value) !void {
    try composition.delta.setOpacity(handle, @floatCast(try finiteNumber(value)));
    composition.stats.applied_properties += 1;
}

fn setClip(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value) !void {
    const enabled = switch (value) {
        .boolean => |item| item,
        else => return error.InvalidProperty,
    };
    try composition.delta.setClip(handle, enabled);
    composition.stats.applied_properties += 1;
}

fn setOffsetX(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value) !void {
    const number = switch (value) {
        .number => |item| item,
        else => return error.InvalidProperty,
    };
    if (!std.math.isFinite(number) or @floor(number) != number or
        number < std.math.minInt(i32) or number > std.math.maxInt(i32)) return error.InvalidProperty;
    try composition.delta.setOffsetX(handle, @intFromFloat(number));
    composition.stats.applied_properties += 1;
}

fn setRadius(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value) !void {
    try composition.delta.setRadius(handle, @floatCast(try finiteNumber(value)));
    composition.stats.applied_properties += 1;
}

fn setPadding(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value) !void {
    const values = array(value, 4) orelse return error.InvalidProperty;
    try composition.delta.setPadding(handle, .{
        .top = try arrayU32(values[0]),
        .right = try arrayU32(values[1]),
        .bottom = try arrayU32(values[2]),
        .left = try arrayU32(values[3]),
    });
    composition.stats.applied_properties += 1;
}

fn setColor(composition: anytype, kind: ui.NodeKind, handle: ui.NodeHandle, value: lua_program.Value) !void {
    const color = try colorValue(value);
    switch (kind) {
        .shape => try composition.delta.setFill(handle, color),
        .text => try composition.delta.setTextColor(handle, color),
        else => return error.InvalidProperty,
    }
    composition.stats.applied_properties += 1;
}

fn setTextColor(composition: anytype, handle: ui.NodeHandle, value: lua_program.Value) !void {
    try composition.delta.setTextColor(handle, try colorValue(value));
    composition.stats.applied_properties += 1;
}

fn finiteNumber(value: lua_program.Value) !f64 {
    return switch (value) {
        .number => |number| if (std.math.isFinite(number) and number >= 0) number else error.InvalidProperty,
        else => error.InvalidProperty,
    };
}

fn integerValue(value: lua_program.Value) !u64 {
    const number = try finiteNumber(value);
    if (@floor(number) != number) return error.InvalidProperty;
    return @intFromFloat(number);
}

fn array(value: lua_program.Value, minimum: usize) ?[]const lua_program.Value {
    return switch (value) {
        .array => |items| if (items.len >= minimum) items else null,
        else => null,
    };
}

fn arrayU32(value: lua_program.Value) !u32 {
    const number = try integerValue(value);
    if (number > std.math.maxInt(u32)) return error.InvalidProperty;
    return @intCast(number);
}

fn colorValue(value: lua_program.Value) !ui.Color {
    const values = array(value, 3) orelse return error.InvalidProperty;
    const alpha = if (values.len >= 4) try finiteNumber(values[3]) else 1;
    const color = ui.Color{
        .r = @floatCast(try finiteNumber(values[0])),
        .g = @floatCast(try finiteNumber(values[1])),
        .b = @floatCast(try finiteNumber(values[2])),
        .a = @floatCast(alpha),
    };
    if (color.r > 1 or color.g > 1 or color.b > 1 or color.a > 1) return error.InvalidProperty;
    return color;
}
