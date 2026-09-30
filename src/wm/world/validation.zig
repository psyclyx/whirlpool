//! Whole-world invariants for flat compositor resource state.

const std = @import("std");
const types = @import("../types.zig");

pub fn validate(world: anytype) !void {
    for (world.outputs.slots.items) |slot| {
        const output = slot.value orelse continue;
        if (world.tags.getConst(output.active_tag) == null) return error.InvalidInvariant;
        if (output.previous_tag) |tag| if (world.tags.getConst(tag) == null) return error.InvalidInvariant;
        try validateRectPair(output.bounds, output.usable);
        try validateOutputConfig(output.configuration);
    }
    for (world.tags.slots.items) |slot| {
        const tag = slot.value orelse continue;
        try validateOptionalName(tag.name);
    }
    for (world.windows.slots.items) |slot| {
        const window = slot.value orelse continue;
        if (world.tags.getConst(window.tag) == null) return error.InvalidInvariant;
        try validateFloatingGeometry(window.floating_geometry);
        try validateSizeHints(window.size_hints);
        try validateOptionalSize(window.actual_size);
        try validateOptionalSize(window.proposed_size);
    }
    if (world.focused) |focused| {
        const window = world.windows.getConst(focused) orelse return error.InvalidInvariant;
        if (!isFocusable(world, window)) return error.InvalidInvariant;
    }
}

/// Whether a window may hold focus: managed, not in the scratchpad, and on a
/// tag some output is showing. This is not on-screen visibility; strip
/// camera, tab selection and fullscreen occlusion are layout state.
pub fn isFocusable(world: anytype, window: *const types.Window) bool {
    if (window.lifecycle != .managed or window.placement == .scratchpad) return false;
    // A window is where its tag is shown; a tag nobody shows has no focusable windows.
    for (world.outputs.slots.items) |slot| {
        const output = slot.value orelse continue;
        if (output.active_tag == window.tag) return true;
    }
    return false;
}

pub fn validateOptionalSize(value: ?types.Size) !void {
    if (value) |size| if (size.width == 0 or size.height == 0) return error.InvalidDimensions;
}

pub fn validateRectPair(bounds: types.Rect, usable: types.Rect) !void {
    if (usable.x < bounds.x or usable.y < bounds.y or usable.right() > bounds.right() or usable.bottom() > bounds.bottom())
        return error.InvalidUsableRect;
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    try validateOptionalName(name);
}

pub fn validateOptionalName(name: []const u8) !void {
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
}

pub fn validateOutputConfig(configuration: types.OutputConfig) !void {
    if (!types.isFinitePositive(configuration.scale) or configuration.scale > 16) return error.InvalidOutputConfig;
    if (configuration.mode) |mode| if (mode.width == 0 or mode.height == 0) return error.InvalidOutputConfig;
}

pub fn validateFloatingGeometry(geometry: types.Rect) !void {
    if (geometry.width == 0 or geometry.height == 0) return error.InvalidFloatingGeometry;
    const right = @as(i64, geometry.x) + @as(i64, geometry.width);
    const bottom = @as(i64, geometry.y) + @as(i64, geometry.height);
    if (right > std.math.maxInt(i32) or bottom > std.math.maxInt(i32)) return error.InvalidFloatingGeometry;
}

pub fn validateSizeHints(hints: types.SizeHints) !void {
    if (hints.max.width != 0 and hints.min.width > hints.max.width) return error.InvalidDimensionsHint;
    if (hints.max.height != 0 and hints.min.height > hints.max.height) return error.InvalidDimensionsHint;
}
