//! Command dispatch for an in-progress flat World transaction.

const std = @import("std");
const command = @import("../command.zig");
const policy = @import("policy.zig");

pub fn one(world: anytype, item: command.Command) !void {
    switch (item) {
        .focus => |value| switch (value) {
            .window => |window| try policy.focusWindowInPlace(world, window),
            .output => |output| try policy.focusOutputInPlace(world, output),
            .clear => policy.clearFocusInPlace(world),
        },
        .tag => |value| switch (value) {
            .activate => |item_value| try policy.setActiveTagInPlace(world, item_value.output, item_value.tag),
            .toggle => |item_value| try policy.toggleActiveTagInPlace(world, item_value.output, item_value.tag),
            .rename => |item_value| try policy.renameTagInPlace(world, item_value.tag, item_value.name),
            .remove => |tag| try policy.removeTagInPlace(world, tag),
        },
        .output => |value| switch (value) {
            .update => |item_value| try policy.updateOutputInPlace(world, item_value.output, .{
                .active_tag = item_value.active_tag,
                .bounds = item_value.bounds,
                .usable = item_value.usable,
                .configuration = item_value.configuration,
            }),
            .configure => |item_value| try policy.configureOutputInPlace(world, item_value.output, item_value.configuration),
            .remove => |output| try policy.removeOutputInPlace(world, output),
        },
        .window => |value| switch (value) {
            .assign => |item_value| try policy.assignWindowInPlace(world, item_value.window, item_value.tag),
            .set_placement => |item_value| try policy.setPlacementInPlace(world, item_value.window, item_value.placement),
            .transition_placement => |item_value| try policy.transitionPlacementInPlace(world, item_value.window, item_value.transition),
            .set_floating_geometry => |item_value| try policy.setFloatingGeometryInPlace(world, item_value.window, item_value.geometry),
            .update_sizing => |item_value| try policy.updateWindowSizingInPlace(world, item_value.window, item_value.hints, item_value.actual, item_value.proposed),
            .set_transient => |item_value| try policy.setWindowTransientInPlace(world, item_value.window, item_value.transient),
            .manage => |window| try policy.manageWindowInPlace(world, window),
            .begin_close => |window| try policy.beginCloseInPlace(world, window),
            .destroy => |window| try policy.destroyWindowInPlace(world, window),
        },
    }
    if (std.debug.runtime_safety) world.validate() catch unreachable;
}
