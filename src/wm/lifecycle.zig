//! Normalized compositor lifecycle facts applied to the flat WM world.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");
const world_mod = @import("world.zig");

pub const World = world_mod.World;
pub const WindowId = ids.WindowId;
pub const OutputId = ids.OutputId;
pub const TagId = ids.TagId;
pub const Rect = types.Rect;
pub const Placement = types.Placement;
pub const PlacementTransition = types.PlacementTransition;

pub const OutputFact = struct {
    output: OutputId,
    active_tag: TagId,
    bounds: Rect,
    usable: Rect,
};

pub const Event = union(enum) {
    tag_announced,
    tag_removed: TagId,
    output_announced: types.OutputSpec,
    output_reconciled: OutputFact,
    output_removed: OutputId,
    window_announced: types.WindowSpec,
    window_managed: WindowId,
    window_close_requested: WindowId,
    window_destroyed: WindowId,
    window_assigned: struct { window: WindowId, tag: TagId, output: ?OutputId },
    placement: struct { window: WindowId, transition: PlacementTransition },
};

pub const ApplyResult = struct {
    changed: bool = true,
    announced_tag: ?TagId = null,
    announced_output: ?OutputId = null,
    announced_window: ?WindowId = null,
    focused: ?WindowId = null,
};

pub fn applyEvent(world: *World, event: Event) !ApplyResult {
    var result = ApplyResult{};
    switch (event) {
        .tag_announced => result.announced_tag = try world.createTag(),
        .tag_removed => |tag| _ = try world.applyAtomically(&.{.{ .tag = .{ .remove = tag } }}),
        .output_announced => |spec| result.announced_output = try world.createOutput(spec),
        .output_reconciled => |fact| try reconcileOutput(world, fact),
        .output_removed => |output| _ = try world.applyAtomically(&.{.{ .output = .{ .remove = output } }}),
        .window_announced => |spec| result.announced_window = try world.createWindow(spec),
        .window_managed => |window| _ = try world.applyAtomically(&.{.{ .window = .{ .manage = window } }}),
        .window_close_requested => |window| _ = try world.applyAtomically(&.{.{ .window = .{ .begin_close = window } }}),
        .window_destroyed => |window| _ = try world.applyAtomically(&.{.{ .window = .{ .destroy = window } }}),
        .window_assigned => |value| _ = try world.applyAtomically(&.{.{ .window = .{ .assign = .{
            .window = value.window,
            .tag = value.tag,
            .output = value.output,
        } } }}),
        .placement => |value| _ = try world.applyAtomically(&.{.{ .window = .{ .transition_placement = .{
            .window = value.window,
            .transition = value.transition,
        } } }}),
    }
    result.focused = world.focusedWindow();
    return result;
}

pub fn reconcileOutput(world: *World, fact: OutputFact) !void {
    const current = world.getOutput(fact.output) orelse return error.UnknownOutput;
    if (current.active_tag == fact.active_tag and std.meta.eql(current.bounds, fact.bounds) and std.meta.eql(current.usable, fact.usable)) return;
    _ = try world.applyAtomically(&.{.{ .output = .{ .update = .{
        .output = fact.output,
        .active_tag = fact.active_tag,
        .bounds = fact.bounds,
        .usable = fact.usable,
        .configuration = current.configuration,
    } } }});
}

test "lifecycle admission does not require a layout destination" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = (try applyEvent(&world, .tag_announced)).announced_tag.?;
    const output = (try applyEvent(&world, .{ .output_announced = .{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    } })).announced_output.?;
    const window = (try applyEvent(&world, .{ .window_announced = .{ .tag = tag, .output = output } })).announced_window.?;
    _ = try applyEvent(&world, .{ .window_managed = window });
    try std.testing.expectEqual(types.Lifecycle.managed, world.getWindow(window).?.lifecycle);
}
