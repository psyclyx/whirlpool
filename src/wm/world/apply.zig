//! Semantic command dispatch for an in-progress World transaction.

const std = @import("std");
const command = @import("../command.zig");
const world_policy = @import("policy.zig");
const world_tree = @import("tree.zig");

const Command = command.Command;

/// Apply one command to a private transaction candidate.
pub fn one(world: anytype, item: Command) !void {
    switch (item) {
        .focus => |value| try focus(world, value),
        .tree => |value| try tree(world, value),
        .geometry => |value| try geometry(world, value),
        .tag => |value| try tag(world, value),
        .mark => |value| try mark(world, value),
        .transfer => |value| try transfer(world, value),
        .output => |value| try output(world, value),
        .window => |value| try window(world, value),
    }
    if (std.debug.runtime_safety) world.validate() catch unreachable;
}

fn focus(world: anytype, item: command.Focus) !void {
    switch (item) {
        .window => |id| try world_tree.focusWindowInPlace(world, id),
        .direction => |value| try world_tree.focusDirectionInPlace(world, value.output, value.direction),
        .mark => |name| try world_policy.focusMarkInPlace(world, name),
    }
}

fn tree(world: anytype, item: command.Tree) !void {
    switch (item) {
        .swap_direction => |value| try world_tree.swapDirectionInPlace(world, value.output, value.direction),
        .insert_window => |value| try world_tree.insertWindowInPlace(world, value.window, value.column),
        .move_node => |value| try world_tree.moveNodeInPlace(world, value.node, value.column),
        .swap_nodes => |value| try world_tree.swapNodesInPlace(world, value.first, value.second),
        .wrap_node => |value| _ = try world_tree.wrapNodeInPlace(world, value.node, value.mode, value.axis),
        .unwrap_node => |id| try world_tree.unwrapNodeInPlace(world, id),
        .set_container_mode => |value| try world_tree.setContainerModeInPlace(world, value.node, value.mode, value.axis),
        .set_active_tab => |value| try world_tree.setActiveTabInPlace(world, value.container, value.child),
        .absorb => |value| try world_tree.absorbInPlace(world, value.output, value.direction),
        .eject => |id| try world_tree.ejectInPlace(world, id),
        .expel => |value| try world_tree.expelInPlace(world, value.node, value.direction),
        .remove_column => |id| try world_policy.removeColumnInPlace(world, id),
    }
}

fn geometry(world: anytype, item: command.Geometry) !void {
    switch (item) {
        .resize_column => |value| try world_policy.resizeColumnInPlace(world, value.column, value.width),
        .cycle_column_width => |value| try world_policy.cycleColumnWidthInPlace(world, value.column, value.step),
        .resize_split => |value| try world_policy.resizeSplitInPlace(world, value.split, value.child, value.weight),
        .move_floating => |value| try world_policy.moveFloatingInPlace(world, value.window, value.delta),
        .resize_floating => |value| try world_policy.resizeFloatingInPlace(world, value.window, value.edges, value.delta),
        .set_camera_target => |value| try world_policy.setCameraTargetInPlace(world, value.tag, value.target),
    }
}

fn tag(world: anytype, item: command.Tag) !void {
    switch (item) {
        .activate => |value| try world_policy.setActiveTagInPlace(world, value.output, value.tag),
        .toggle => |value| try world_policy.toggleActiveTagInPlace(world, value.output, value.tag),
        .rename => |value| try world_policy.renameTagInPlace(world, value.tag, value.name),
        .remove => |id| try world_policy.removeTagInPlace(world, id),
    }
}

fn mark(world: anytype, item: command.Mark) !void {
    switch (item) {
        .set => |value| try world_policy.setMarkInPlace(world, value.window, value.name),
        .clear => |value| try world_policy.clearMarkInPlace(world, value.window, value.name),
    }
}

fn transfer(world: anytype, item: command.Transfer) !void {
    switch (item) {
        .send_window => |value| try world_policy.sendWindowInPlace(world, value),
        .send_focused => |value| try world_policy.sendFocusedWindowInPlace(world, value.source_output, value.tag, value.output),
        .summon_window => |value| try world_policy.summonWindowInPlace(world, value.window, value.output),
        .summon_mark => |value| try world_policy.summonMarkInPlace(world, value.name, value.output),
    }
}

fn output(world: anytype, item: command.Output) !void {
    switch (item) {
        .update => |value| try world_policy.updateOutputInPlace(world, value.output, .{
            .active_tag = value.active_tag,
            .bounds = value.bounds,
            .usable = value.usable,
            .configuration = value.configuration,
        }),
        .configure => |value| try world_policy.configureOutputInPlace(world, value.output, value.configuration),
        .remove => |id| try world_policy.removeOutputInPlace(world, id),
    }
}

fn window(world: anytype, item: command.Window) !void {
    switch (item) {
        .set_output => |value| try world_policy.setWindowOutputInPlace(world, value.window, value.output),
        .set_placement => |value| try world_policy.setPlacementInPlace(world, value.window, value.placement),
        .transition_placement => |value| try world_policy.transitionPlacementInPlace(world, value.window, value.transition),
        .update_sizing => |value| try world_policy.updateWindowSizingInPlace(world, value.window, value.hints, value.actual, value.proposed),
        .begin_close => |id| try beginClose(world, id),
        .destroy => |id| try world_tree.destroyWindowInPlace(world, id),
    }
}

fn beginClose(world: anytype, window_id: anytype) !void {
    const value = world.windows.get(window_id) orelse return error.UnknownWindow;
    if (value.lifecycle != .managed) return error.InvalidLifecycle;
    value.lifecycle = .closing;
    world_tree.repairFocus(world, value.tag);
}
