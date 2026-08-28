//! WM lifecycle composition over the authoritative World.
//!
//! This is the boundary between protocol-shaped facts and WM policy.  It
//! owns no tree state: structural changes are expressed as World commands,
//! while focus repair walks an immutable WorldView in a fixed order.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");
const command = @import("command.zig");
const world_mod = @import("world.zig");

pub const World = world_mod.World;
pub const WorldView = world_mod.WorldView;
pub const WindowId = ids.WindowId;
pub const OutputId = ids.OutputId;
pub const TagId = ids.TagId;
pub const ColumnId = ids.ColumnId;
pub const NodeId = ids.NodeId;
pub const Rect = types.Rect;
pub const Placement = types.Placement;
pub const PlacementTransition = types.PlacementTransition;

pub const OutputFact = struct {
    output: OutputId,
    active_tag: TagId,
    bounds: Rect,
    usable: Rect,
};

pub const FocusMode = enum {
    /// Retain a valid current focus; otherwise choose the first candidate.
    preserve,
    /// Ignore the current focus and choose the first candidate.  Used when
    /// the focused window is closing or has been destroyed.
    deterministic_successor,
};

pub const Event = union(enum) {
    tag_announced,
    tag_removed: TagId,
    output_announced: types.OutputSpec,
    output_reconciled: OutputFact,
    output_removed: OutputId,
    window_announced: types.WindowSpec,
    window_managed: struct { window: WindowId, column: ColumnId },
    window_close_requested: WindowId,
    window_destroyed: WindowId,
    window_output_changed: struct { window: WindowId, output: ?OutputId },
    window_moved: struct { window: WindowId, column: ColumnId },
    placement: struct { window: WindowId, transition: PlacementTransition },
    repair_output_focus: struct { output: OutputId, mode: FocusMode = .preserve },
};

pub const ApplyResult = struct {
    changed: bool = true,
    announced_tag: ?TagId = null,
    announced_output: ?OutputId = null,
    announced_window: ?WindowId = null,
    focused: ?WindowId = null,
};

/// Apply one normalized lifecycle fact.  Every existing-object mutation is a
/// World transaction; a rejected event leaves that event's state untouched.
pub fn applyEvent(world: *World, event: Event) !ApplyResult {
    var result = ApplyResult{};
    switch (event) {
        .tag_announced => result.announced_tag = try world.createTag(),
        .tag_removed => |tag| _ = try world.applyAtomically(&.{.{ .tag = .{ .remove = tag } }}),
        .output_announced => |spec| result = try announceOutput(world, spec),
        .output_reconciled => |fact| result.focused = try updateOutput(world, fact),
        .output_removed => |output| _ = try world.applyAtomically(&.{.{ .output = .{ .remove = output } }}),
        .window_announced => |spec| result.announced_window = try world.createWindow(spec),
        .window_managed => |value| {
            result.focused = try manageWindow(world, value.window, value.column);
        },
        .window_close_requested => |window| {
            result.focused = try beginWindowClose(world, window);
        },
        .window_destroyed => |window| {
            result.focused = try destroyWindow(world, window);
        },
        .window_output_changed => |value| {
            result.focused = try changeWindowOutput(world, value.window, value.output);
        },
        .window_moved => |value| {
            result.focused = try moveWindow(world, value.window, value.column);
        },
        .placement => |value| {
            result.focused = try changePlacement(world, value.window, value.transition);
        },
        .repair_output_focus => |value| result.focused = try repairFocus(world, value.output, value.mode),
    }
    if (result.announced_tag) |id| std.debug.assert(id.isValid());
    if (result.announced_output) |id| std.debug.assert(id.isValid());
    if (result.announced_window) |id| std.debug.assert(id.isValid());
    if (result.focused) |id| std.debug.assert(id.isValid());
    return result;
}

fn announceOutput(world: *World, spec: types.OutputSpec) !ApplyResult {
    const output = try world.createOutput(spec);
    std.debug.assert(world.getOutput(output) != null);
    return .{ .announced_output = output, .focused = try repairFocus(world, output, .preserve) };
}

fn updateOutput(world: *World, fact: OutputFact) !?WindowId {
    std.debug.assert(fact.output.isValid());
    try reconcileOutput(world, fact);
    return repairFocus(world, fact.output, .preserve);
}

fn manageWindow(world: *World, window: WindowId, column: ColumnId) !?WindowId {
    std.debug.assert(window.isValid());
    std.debug.assert(column.isValid());
    _ = try world.applyAtomically(&.{.{ .tree = .{ .insert_window = .{ .window = window, .column = column } } }});
    return repairWindowOutput(world, window, .preserve);
}

fn beginWindowClose(world: *World, window: WindowId) !?WindowId {
    var before = world.view();
    const output = try windowOutput(&before, window);
    const was_focused = try isFocused(&before, window);
    _ = try world.applyAtomically(&.{.{ .window = .{ .begin_close = window } }});
    return if (output) |id| repairFocus(world, id, focusModeAfterRemoval(was_focused)) else null;
}

fn destroyWindow(world: *World, window: WindowId) !?WindowId {
    var before = world.view();
    const output = try windowOutput(&before, window);
    const was_focused = try isFocused(&before, window);
    _ = try world.applyAtomically(&.{.{ .window = .{ .destroy = window } }});
    std.debug.assert(world.getWindow(window) == null);
    const output_id = output orelse return null;
    if (world.getOutput(output_id) == null) return null;
    return repairFocus(world, output_id, focusModeAfterRemoval(was_focused));
}

fn focusModeAfterRemoval(was_focused: bool) FocusMode {
    return if (was_focused) .deterministic_successor else .preserve;
}

fn changeWindowOutput(world: *World, window: WindowId, new_output: ?OutputId) !?WindowId {
    var before = world.view();
    const old_output = try windowOutput(&before, window);
    _ = try world.applyAtomically(&.{.{ .window = .{ .set_output = .{ .window = window, .output = new_output } } }});
    var focused: ?WindowId = null;
    if (old_output) |output| {
        if (world.getOutput(output) != null) focused = try repairFocus(world, output, .preserve);
    }
    if (new_output) |output| focused = try repairFocus(world, output, .preserve);
    return focused;
}

fn moveWindow(world: *World, window: WindowId, column: ColumnId) !?WindowId {
    var before = world.view();
    const output = try windowOutput(&before, window);
    const node = before.nodeForWindow(window) orelse return error.NotManaged;
    _ = try world.applyAtomically(&.{.{ .tree = .{ .move_node = .{ .node = node, .column = column } } }});
    return if (output) |id| repairFocus(world, id, .preserve) else null;
}

fn changePlacement(world: *World, window: WindowId, transition: PlacementTransition) !?WindowId {
    var before = world.view();
    const output = try windowOutput(&before, window);
    const previous = (before.getWindow(window) orelse return error.UnknownWindow).placement;
    _ = try world.applyAtomically(&.{.{ .window = .{ .transition_placement = .{ .window = window, .transition = transition } } }});
    const output_id = output orelse return null;
    const current = world.getWindow(window).?.placement;
    if (previous == .scratchpad and current != .scratchpad and isActiveOutput(world, window, output_id)) {
        _ = try world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
        return window;
    }
    const mode: FocusMode = if (current == .scratchpad or (previous == .fullscreen and current != .fullscreen))
        .deterministic_successor
    else
        .preserve;
    return repairFocus(world, output_id, mode);
}

/// Reconcile protocol geometry and the active tag without rebuilding any
/// columns or nodes.  Output identity is already owned by World.
pub fn reconcileOutput(world: *World, fact: OutputFact) !void {
    var snapshot = world.view();
    const current = snapshot.getOutput(fact.output) orelse return error.UnknownOutput;
    if (current.active_tag == fact.active_tag and
        std.meta.eql(current.bounds, fact.bounds) and
        std.meta.eql(current.usable, fact.usable)) return;
    _ = try world.applyAtomically(&.{.{ .output = .{ .update = .{
        .output = fact.output,
        .active_tag = fact.active_tag,
        .bounds = fact.bounds,
        .usable = fact.usable,
        .configuration = current.configuration,
    } } }});
}

/// Select a focus target using only snapshot-owned data.  Traversal order is
/// output order, column order, then tree order; tabbed containers contribute
/// only their active child.  This makes repair independent of hash-map or
/// slot allocation order.
pub fn chooseFocus(snapshot: *const WorldView, output_id: OutputId, mode: FocusMode) !?WindowId {
    const output = snapshot.getOutput(output_id) orelse return error.UnknownOutput;
    const tag = snapshot.getTag(output.active_tag) orelse return error.InvalidInvariant;

    if (mode == .preserve) if (tag.focused) |node_id| {
        if (try candidateAt(snapshot, output_id, output.active_tag, node_id)) |window| return window;
    };

    for (tag.columns.items) |column_id| {
        const column = snapshot.getColumn(column_id) orelse return error.InvalidInvariant;
        if (try firstCandidate(snapshot, output_id, output.active_tag, column.root)) |window| return window;
    }
    return null;
}

/// Repair the active tag's focus in the mutable World using a snapshot-based
/// decision.  The focus command remains the sole writer of focus serials.
pub fn repairFocus(world: *World, output_id: OutputId, mode: FocusMode) !?WindowId {
    var snapshot = world.view();
    const selected = try chooseFocus(&snapshot, output_id, mode);
    if (selected) |window| _ = try world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
    return selected;
}

fn repairWindowOutput(world: *World, window_id: WindowId, mode: FocusMode) !?WindowId {
    const window = world.getWindow(window_id) orelse return error.UnknownWindow;
    const output = window.output orelse return null;
    if (world.getOutput(output) == null) return error.UnknownOutput;
    return repairFocus(world, output, mode);
}

fn windowOutput(snapshot: *const WorldView, window_id: WindowId) !?OutputId {
    return (snapshot.getWindow(window_id) orelse return error.UnknownWindow).output;
}

fn isFocused(snapshot: *const WorldView, window_id: WindowId) !bool {
    const window = snapshot.getWindow(window_id) orelse return error.UnknownWindow;
    const tag = snapshot.getTag(window.tag) orelse return error.InvalidInvariant;
    const node = tag.focused orelse return false;
    return snapshot.getNode(node) != null and snapshot.getNode(node).?.window == window_id;
}

fn isActiveOutput(world: *const World, window_id: WindowId, output_id: OutputId) bool {
    const window = world.getWindow(window_id) orelse return false;
    const output = world.getOutput(output_id) orelse return false;
    return window.output == output_id and window.tag == output.active_tag;
}

fn firstCandidate(snapshot: *const WorldView, output_id: OutputId, tag_id: TagId, maybe_node: ?NodeId) !?WindowId {
    const node_id = maybe_node orelse return null;
    const node = snapshot.getNode(node_id) orelse return error.InvalidInvariant;
    if (node.isLeaf()) return candidateAt(snapshot, output_id, tag_id, node_id);
    if (node.mode == .tabbed) {
        if (node.active_child >= node.children.items.len) return error.InvalidInvariant;
        return firstCandidate(snapshot, output_id, tag_id, node.children.items[node.active_child].id);
    }
    for (node.children.items) |child| {
        if (try firstCandidate(snapshot, output_id, tag_id, child.id)) |window| return window;
    }
    return null;
}

fn candidateAt(snapshot: *const WorldView, output_id: OutputId, tag_id: TagId, node_id: NodeId) !?WindowId {
    const node = snapshot.getNode(node_id) orelse return null;
    const window_id = node.window orelse return null;
    const window = snapshot.getWindow(window_id) orelse return error.InvalidInvariant;
    if (window.tag != tag_id or window.output != output_id or window.lifecycle != .managed or window.placement == .scratchpad) return null;
    if (snapshot.nodeForWindow(window_id) != node_id) return error.InvalidInvariant;
    const tag = snapshot.getTag(tag_id) orelse return error.InvalidInvariant;
    var active = false;
    for (tag.columns.items) |column_id| {
        const column = snapshot.getColumn(column_id) orelse return error.InvalidInvariant;
        if (try activeNodeContains(snapshot, column.root, node_id)) {
            active = true;
            break;
        }
    }
    if (!active) return null;
    return window_id;
}

fn activeNodeContains(snapshot: *const WorldView, maybe_node: ?NodeId, wanted: NodeId) !bool {
    const node_id = maybe_node orelse return false;
    if (node_id == wanted) return true;
    const node = snapshot.getNode(node_id) orelse return error.InvalidInvariant;
    if (node.mode == .tabbed) {
        if (node.active_child >= node.children.items.len) return error.InvalidInvariant;
        return activeNodeContains(snapshot, node.children.items[node.active_child].id, wanted);
    }
    for (node.children.items) |child| {
        if (try activeNodeContains(snapshot, child.id, wanted)) return true;
    }
    return false;
}

fn desktop(allocator: std.mem.Allocator) !struct { world: World, tag: TagId, output: OutputId, column: ColumnId } {
    var world = World.init(allocator);
    errdefer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    return .{ .world = world, .tag = tag, .output = output, .column = column };
}

test "output reconciliation changes only output facts and repairs tags" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const other_tag = try fixture.world.createTag();
    const result = try applyEvent(&fixture.world, .{ .output_reconciled = .{
        .output = fixture.output,
        .active_tag = other_tag,
        .bounds = .{ .x = 10, .y = 20, .width = 1000, .height = 700 },
        .usable = .{ .x = 10, .y = 20, .width = 1000, .height = 680 },
    } });
    try std.testing.expectEqual(other_tag, fixture.world.getOutput(fixture.output).?.active_tag);
    try std.testing.expect(result.focused == null);
    try fixture.world.validate();
}

test "lifecycle events are atomic per event and preserve tree ownership" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const announced = (try applyEvent(&fixture.world, .{ .window_announced = .{ .tag = fixture.tag, .output = fixture.output } })).announced_window.?;
    _ = try applyEvent(&fixture.world, .{ .window_managed = .{ .window = announced, .column = fixture.column } });
    const node = fixture.world.nodeForWindow(announced).?;
    try std.testing.expectError(error.UnknownColumn, applyEvent(&fixture.world, .{ .window_moved = .{ .window = announced, .column = ColumnId.fromParts(99, 1) } }));
    try std.testing.expectEqual(node, fixture.world.nodeForWindow(announced).?);
    try fixture.world.validate();
}

test "fullscreen and scratchpad transitions restore placement without rebuilding nodes" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const window = (try applyEvent(&fixture.world, .{ .window_announced = .{ .tag = fixture.tag, .output = fixture.output, .placement = .tiled } })).announced_window.?;
    _ = try applyEvent(&fixture.world, .{ .window_managed = .{ .window = window, .column = fixture.column } });
    const node = fixture.world.nodeForWindow(window).?;
    _ = try applyEvent(&fixture.world, .{ .placement = .{ .window = window, .transition = .floating } });
    _ = try applyEvent(&fixture.world, .{ .placement = .{ .window = window, .transition = .fullscreen } });
    try std.testing.expectEqual(Placement.fullscreen, fixture.world.getWindow(window).?.placement);
    _ = try applyEvent(&fixture.world, .{ .placement = .{ .window = window, .transition = .exit_fullscreen } });
    try std.testing.expectEqual(Placement.floating, fixture.world.getWindow(window).?.placement);
    _ = try applyEvent(&fixture.world, .{ .placement = .{ .window = window, .transition = .toggle_scratchpad } });
    try std.testing.expectEqual(Placement.scratchpad, fixture.world.getWindow(window).?.placement);
    _ = try applyEvent(&fixture.world, .{ .placement = .{ .window = window, .transition = .toggle_scratchpad } });
    try std.testing.expectEqual(Placement.floating, fixture.world.getWindow(window).?.placement);
    try std.testing.expectEqual(node, fixture.world.nodeForWindow(window).?);
    try fixture.world.validate();
}

test "focus repair uses tree order after focused destruction" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    var windows: [3]WindowId = undefined;
    for (&windows) |*window| {
        window.* = (try applyEvent(&fixture.world, .{ .window_announced = .{ .tag = fixture.tag, .output = fixture.output } })).announced_window.?;
        _ = try applyEvent(&fixture.world, .{ .window_managed = .{ .window = window.*, .column = fixture.column } });
    }
    _ = try fixture.world.applyAtomically(&.{.{ .focus = .{ .window = windows[1] } }});
    const result = try applyEvent(&fixture.world, .{ .window_destroyed = windows[1] });
    try std.testing.expectEqual(windows[0], result.focused.?);
    try std.testing.expectEqual(windows[0], fixture.world.getNode(fixture.world.getTag(fixture.tag).?.focused.?).?.window.?);
    try fixture.world.validate();
}

test "scratchpad windows never become focus candidates" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const window = (try applyEvent(&fixture.world, .{ .window_announced = .{ .tag = fixture.tag, .output = fixture.output, .placement = .scratchpad } })).announced_window.?;
    _ = try applyEvent(&fixture.world, .{ .window_managed = .{ .window = window, .column = fixture.column } });
    var snapshot = fixture.world.view();
    try std.testing.expectEqual(@as(?WindowId, null), try chooseFocus(&snapshot, fixture.output, .deterministic_successor));
}

test "focus repair skips inactive tab descendants" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const first = (try applyEvent(&fixture.world, .{ .window_announced = .{ .tag = fixture.tag, .output = fixture.output } })).announced_window.?;
    _ = try applyEvent(&fixture.world, .{ .window_managed = .{ .window = first, .column = fixture.column } });
    const first_node = fixture.world.nodeForWindow(first).?;
    _ = try fixture.world.applyAtomically(&.{.{ .tree = .{ .wrap_node = .{ .node = first_node, .mode = .tabbed, .axis = .vertical } } }});
    const second = (try applyEvent(&fixture.world, .{ .window_announced = .{ .tag = fixture.tag, .output = fixture.output } })).announced_window.?;
    _ = try applyEvent(&fixture.world, .{ .window_managed = .{ .window = second, .column = fixture.column } });
    var snapshot = fixture.world.view();
    try std.testing.expectEqual(first, try chooseFocus(&snapshot, fixture.output, .deterministic_successor));
    const container = fixture.world.getColumn(fixture.column).?.root.?;
    _ = try fixture.world.applyAtomically(&.{.{ .tree = .{ .set_active_tab = .{ .container = container, .child = fixture.world.nodeForWindow(second).? } } }});
    snapshot = fixture.world.view();
    try std.testing.expectEqual(second, try chooseFocus(&snapshot, fixture.output, .deterministic_successor));
}
