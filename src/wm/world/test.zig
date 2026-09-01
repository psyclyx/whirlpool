const std = @import("std");
const world_mod = @import("../world.zig");
const types = @import("../types.zig");

const World = world_mod.World;

fn desktop(allocator: std.mem.Allocator) !struct { world: World, tag: world_mod.TagId, output: world_mod.OutputId } {
    var world = World.init(allocator);
    errdefer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    return .{ .world = world, .tag = tag, .output = output };
}

test "windows are admitted without native layout structure" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const window = try fixture.world.createWindow(.{ .tag = fixture.tag, .output = fixture.output });
    try fixture.world.manageWindow(window);
    _ = try fixture.world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
    try std.testing.expectEqual(types.Lifecycle.managed, fixture.world.getWindow(window).?.lifecycle);
    try std.testing.expectEqual(window, fixture.world.focusedWindow().?);
    try fixture.world.validate();
}

test "failed resource batch is atomic" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const window = try fixture.world.createWindow(.{ .tag = fixture.tag, .output = fixture.output });
    try fixture.world.manageWindow(window);
    const epoch = fixture.world.epoch();
    try std.testing.expectError(error.UnknownTag, fixture.world.applyAtomically(&.{
        .{ .window = .{ .set_placement = .{ .window = window, .placement = .floating } } },
        .{ .window = .{ .assign = .{ .window = window, .tag = world_mod.TagId.fromParts(99, 1), .output = fixture.output } } },
    }));
    try std.testing.expectEqual(epoch, fixture.world.epoch());
    try std.testing.expectEqual(types.Placement.tiled, fixture.world.getWindow(window).?.placement);
}

test "workspace changes clear invalid physical focus" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const second_tag = try fixture.world.createTag();
    const window = try fixture.world.createWindow(.{ .tag = fixture.tag, .output = fixture.output });
    try fixture.world.manageWindow(window);
    _ = try fixture.world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
    _ = try fixture.world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = fixture.output, .tag = second_tag } } }});
    try std.testing.expectEqual(@as(?world_mod.WindowId, null), fixture.world.focusedWindow());
}

test "checkpoint and persistence preserve only flat facts" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const window = try fixture.world.createWindow(.{ .tag = fixture.tag, .output = fixture.output });
    try fixture.world.manageWindow(window);
    var checkpoint = try fixture.world.checkpoint();
    defer checkpoint.deinit();
    var saved = try fixture.world.saveState();
    defer saved.deinit();
    _ = try fixture.world.applyAtomically(&.{.{ .window = .{ .set_floating_geometry = .{
        .window = window,
        .geometry = .{ .x = 12, .y = 14, .width = 320, .height = 200 },
    } } }});
    try std.testing.expectEqual(@as(i32, 0), checkpoint.getWindow(window).?.floating_geometry.x);
    try fixture.world.restoreState(&saved);
    try std.testing.expectEqual(@as(i32, 0), fixture.world.getWindow(window).?.floating_geometry.x);
}
