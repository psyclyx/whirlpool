//! Flat resource, workspace-membership, and physical-focus mutations.

const std = @import("std");
const ids = @import("../ids.zig");
const types = @import("../types.zig");
const validation = @import("validation.zig");

pub fn focusWindowInPlace(world: anytype, window_id: ids.WindowId) !void {
    const window = world.windows.getConst(window_id) orelse return error.UnknownWindow;
    if (!validation.isVisible(world, window)) return error.NotFocusable;
    world.focused = window_id;
}

pub fn clearFocusInPlace(world: anytype) void {
    world.focused = null;
}

pub fn manageWindowInPlace(world: anytype, window_id: ids.WindowId) !void {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle != .announced) return error.InvalidLifecycle;
    window.lifecycle = .managed;
}

pub fn beginCloseInPlace(world: anytype, window_id: ids.WindowId) !void {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle != .managed) return error.InvalidLifecycle;
    window.lifecycle = .closing;
    clearInvalidFocus(world);
}

pub fn destroyWindowInPlace(world: anytype, window_id: ids.WindowId) !void {
    _ = world.windows.getConst(window_id) orelse return error.UnknownWindow;
    if (world.focused == window_id) world.focused = null;
    try world.windows.discard(window_id);
}

pub fn assignWindowInPlace(world: anytype, window_id: ids.WindowId, tag_id: ids.TagId, output_id: ?ids.OutputId) !void {
    _ = world.tags.getConst(tag_id) orelse return error.UnknownTag;
    if (output_id) |output| _ = world.outputs.getConst(output) orelse return error.UnknownOutput;
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    window.tag = tag_id;
    window.output = output_id;
    clearInvalidFocus(world);
}

pub fn setPlacementInPlace(world: anytype, window_id: ids.WindowId, placement: types.Placement) !void {
    const window = try managedWindow(world, window_id);
    window.placement = placement;
    switch (placement) {
        .unplaced => {},
        .tiled => window.restore_placement = .tiled,
        .floating => window.restore_placement = .floating,
        .fullscreen, .scratchpad => {},
    }
    clearInvalidFocus(world);
}

pub fn transitionPlacementInPlace(world: anytype, window_id: ids.WindowId, transition: types.PlacementTransition) !void {
    const window = try managedWindow(world, window_id);
    switch (transition) {
        .tiled => {
            window.placement = .tiled;
            window.restore_placement = .tiled;
        },
        .floating => {
            window.placement = .floating;
            window.restore_placement = .floating;
        },
        .fullscreen => if (window.placement != .fullscreen) {
            window.restore_placement = restored(window.placement, window.restore_placement);
            window.placement = .fullscreen;
        },
        .scratchpad => if (window.placement != .scratchpad) {
            window.restore_placement = restored(window.placement, window.restore_placement);
            window.placement = .scratchpad;
        },
        .exit_fullscreen => {
            if (window.placement != .fullscreen) return error.NotFullscreen;
            window.placement = fromRestored(window.restore_placement);
        },
        .toggle_scratchpad => if (window.placement == .scratchpad) {
            window.placement = fromRestored(window.restore_placement);
        } else {
            window.restore_placement = restored(window.placement, window.restore_placement);
            window.placement = .scratchpad;
        },
    }
    clearInvalidFocus(world);
}

pub fn setFloatingGeometryInPlace(world: anytype, window_id: ids.WindowId, geometry: types.Rect) !void {
    try validation.validateFloatingGeometry(geometry);
    const window = try managedWindow(world, window_id);
    window.floating_geometry = geometry;
}

pub fn updateWindowSizingInPlace(world: anytype, window_id: ids.WindowId, hints: types.SizeHints, actual: ?types.Size, proposed: ?types.Size) !void {
    try validation.validateSizeHints(hints);
    try validation.validateOptionalSize(actual);
    try validation.validateOptionalSize(proposed);
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    window.size_hints = hints;
    window.actual_size = actual;
    window.proposed_size = proposed;
}

pub fn setWindowTransientInPlace(world: anytype, window_id: ids.WindowId, transient: bool) !void {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    window.transient = transient;
}

pub fn setActiveTagInPlace(world: anytype, output_id: ids.OutputId, tag_id: ids.TagId) !void {
    _ = world.tags.getConst(tag_id) orelse return error.UnknownTag;
    const output = world.outputs.get(output_id) orelse return error.UnknownOutput;
    if (output.active_tag != tag_id) {
        output.previous_tag = output.active_tag;
        output.active_tag = tag_id;
    }
    clearInvalidFocus(world);
}

pub fn toggleActiveTagInPlace(world: anytype, output_id: ids.OutputId, tag_id: ids.TagId) !void {
    _ = world.tags.getConst(tag_id) orelse return error.UnknownTag;
    const output = world.outputs.get(output_id) orelse return error.UnknownOutput;
    if (output.active_tag != tag_id) return setActiveTagInPlace(world, output_id, tag_id);
    const previous = output.previous_tag orelse return error.NoPreviousTag;
    _ = world.tags.getConst(previous) orelse return error.InvalidInvariant;
    output.previous_tag = output.active_tag;
    output.active_tag = previous;
    clearInvalidFocus(world);
}

pub fn renameTagInPlace(world: anytype, tag_id: ids.TagId, name: []const u8) !void {
    try validation.validateName(name);
    const tag = world.tags.get(tag_id) orelse return error.UnknownTag;
    const owned = try world.allocator.dupe(u8, name);
    world.allocator.free(tag.name);
    tag.name = owned;
}

pub fn removeTagInPlace(world: anytype, tag_id: ids.TagId) !void {
    _ = world.tags.getConst(tag_id) orelse return error.UnknownTag;
    for (world.outputs.slots.items) |slot| if (slot.value) |output| {
        if (output.active_tag == tag_id or output.previous_tag == tag_id) return error.TagInUse;
    };
    for (world.windows.slots.items) |slot| if (slot.value) |window| {
        if (window.tag == tag_id) return error.TagInUse;
    };
    try world.tags.discard(tag_id);
}

pub fn updateOutputInPlace(world: anytype, output_id: ids.OutputId, spec: types.OutputSpec) !void {
    _ = world.tags.getConst(spec.active_tag) orelse return error.UnknownTag;
    try validation.validateRectPair(spec.bounds, spec.usable);
    try validation.validateOutputConfig(spec.configuration);
    const output = world.outputs.get(output_id) orelse return error.UnknownOutput;
    if (output.active_tag != spec.active_tag) output.previous_tag = output.active_tag;
    output.active_tag = spec.active_tag;
    output.bounds = spec.bounds;
    output.usable = spec.usable;
    output.configuration = spec.configuration;
    clearInvalidFocus(world);
}

pub fn configureOutputInPlace(world: anytype, output_id: ids.OutputId, configuration: types.OutputConfig) !void {
    try validation.validateOutputConfig(configuration);
    const output = world.outputs.get(output_id) orelse return error.UnknownOutput;
    output.configuration = configuration;
}

pub fn removeOutputInPlace(world: anytype, output_id: ids.OutputId) !void {
    _ = world.outputs.getConst(output_id) orelse return error.UnknownOutput;
    for (world.windows.slots.items) |*slot| if (slot.value) |*window| {
        if (window.output == output_id) window.output = null;
    };
    try world.outputs.discard(output_id);
    clearInvalidFocus(world);
}

fn managedWindow(world: anytype, window_id: ids.WindowId) !*types.Window {
    const window = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (window.lifecycle != .managed) return error.InvalidLifecycle;
    return window;
}

fn restored(placement: types.Placement, fallback: types.RestoredPlacement) types.RestoredPlacement {
    return switch (placement) {
        .tiled => .tiled,
        .floating => .floating,
        .unplaced, .fullscreen, .scratchpad => fallback,
    };
}

fn fromRestored(value: types.RestoredPlacement) types.Placement {
    return switch (value) {
        .tiled => .tiled,
        .floating => .floating,
    };
}

fn clearInvalidFocus(world: anytype) void {
    const focused = world.focused orelse return;
    const window = world.windows.getConst(focused) orelse {
        world.focused = null;
        return;
    };
    if (!validation.isVisible(world, window)) world.focused = null;
}

test "placement restoration is independent of layout structure" {
    try std.testing.expectEqual(types.RestoredPlacement.floating, restored(.fullscreen, .floating));
}
