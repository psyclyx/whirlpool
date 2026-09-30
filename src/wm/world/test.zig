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
    const window = try fixture.world.createWindow(.{ .tag = fixture.tag });
    try fixture.world.manageWindow(window);
    _ = try fixture.world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
    try std.testing.expectEqual(types.Lifecycle.managed, fixture.world.getWindow(window).?.lifecycle);
    try std.testing.expectEqual(window, fixture.world.focusedWindow().?);
    try fixture.world.validate();
}

test "failed resource batch is atomic" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const window = try fixture.world.createWindow(.{ .tag = fixture.tag });
    try fixture.world.manageWindow(window);
    const epoch = fixture.world.epoch();
    try std.testing.expectError(error.UnknownTag, fixture.world.applyAtomically(&.{
        .{ .window = .{ .set_placement = .{ .window = window, .placement = .floating } } },
        .{ .window = .{ .assign = .{ .window = window, .tag = world_mod.TagId.fromParts(99, 1) } } },
    }));
    try std.testing.expectEqual(epoch, fixture.world.epoch());
    try std.testing.expectEqual(types.Placement.tiled, fixture.world.getWindow(window).?.placement);
}

test "workspace changes clear invalid physical focus" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const second_tag = try fixture.world.createTag();
    const window = try fixture.world.createWindow(.{ .tag = fixture.tag });
    try fixture.world.manageWindow(window);
    _ = try fixture.world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
    _ = try fixture.world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = fixture.output, .tag = second_tag } } }});
    try std.testing.expectEqual(@as(?world_mod.WindowId, null), fixture.world.focusedWindow());
}

test "checkpoint and persistence preserve only flat facts" {
    var fixture = try desktop(std.testing.allocator);
    defer fixture.world.deinit();
    const window = try fixture.world.createWindow(.{ .tag = fixture.tag });
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

test "a tag is shown on at most one output; activating one shown elsewhere is a no-op" {
    var world = world_mod.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: types.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const first_tag = try world.createTag();
    const second_tag = try world.createTag();
    const left = try world.createOutput(.{ .active_tag = first_tag, .bounds = rect, .usable = rect });
    const right = try world.createOutput(.{ .active_tag = second_tag, .bounds = rect, .usable = rect });

    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = left, .tag = second_tag } } }});
    try std.testing.expectEqual(first_tag, world.getOutput(left).?.active_tag);
    try std.testing.expectEqual(second_tag, world.getOutput(right).?.active_tag);
    // Toggling back to a previous tag another output has since taken is also a no-op.
    const third_tag = try world.createTag();
    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = left, .tag = third_tag } } }});
    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = right, .tag = first_tag } } }});
    _ = try world.applyAtomically(&.{.{ .tag = .{ .toggle = .{ .output = left, .tag = third_tag } } }});
    try std.testing.expectEqual(third_tag, world.getOutput(left).?.active_tag);
    try std.testing.expectEqual(first_tag, world.getOutput(right).?.active_tag);
}

test "a window is presented on the output showing its tag" {
    var world = world_mod.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: types.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const first_tag = try world.createTag();
    const second_tag = try world.createTag();
    const left = try world.createOutput(.{ .active_tag = first_tag, .bounds = rect, .usable = rect });
    const right = try world.createOutput(.{ .active_tag = second_tag, .bounds = rect, .usable = rect });
    const window = try world.createWindow(.{ .tag = second_tag });
    try world.manageWindow(window);
    try std.testing.expectEqual(@as(?world_mod.OutputId, right), world.windowOutput(window));

    // Reassigning the window to another tag moves it with no other bookkeeping.
    _ = try world.applyAtomically(&.{.{ .window = .{ .assign = .{ .window = window, .tag = first_tag } } }});
    try std.testing.expectEqual(@as(?world_mod.OutputId, left), world.windowOutput(window));

    // A tag nobody shows has no output, and its windows cannot take focus.
    const hidden_tag = try world.createTag();
    _ = try world.applyAtomically(&.{.{ .window = .{ .assign = .{ .window = window, .tag = hidden_tag } } }});
    try std.testing.expectEqual(@as(?world_mod.OutputId, null), world.windowOutput(window));
    try std.testing.expectError(error.NotFocusable, world.applyAtomically(&.{.{ .focus = .{ .window = window } }}));
}

test "a monitor can be focused without a window" {
    var world = world_mod.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: types.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const first_tag = try world.createTag();
    const second_tag = try world.createTag();
    const left = try world.createOutput(.{ .active_tag = first_tag, .bounds = rect, .usable = rect });
    const right = try world.createOutput(.{ .active_tag = second_tag, .bounds = rect, .usable = rect });
    const window = try world.createWindow(.{ .tag = first_tag });
    try world.manageWindow(window);

    // With nothing focused, the first monitor is focused.
    try std.testing.expectEqual(@as(?world_mod.OutputId, left), world.focusedOutput());
    // Focusing a window focuses its monitor.
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
    try std.testing.expectEqual(@as(?world_mod.OutputId, left), world.focusedOutput());
    // Focusing an empty monitor takes keyboard focus off the window.
    _ = try world.applyAtomically(&.{.{ .focus = .{ .output = right } }});
    try std.testing.expectEqual(@as(?world_mod.OutputId, right), world.focusedOutput());
    try std.testing.expectEqual(@as(?world_mod.WindowId, null), world.focusedWindow());
    // Focusing the monitor a window is on keeps that window focused.
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
    _ = try world.applyAtomically(&.{.{ .focus = .{ .output = left } }});
    try std.testing.expectEqual(@as(?world_mod.WindowId, window), world.focusedWindow());
    // Switching the focused monitor's tag drops the window but not the monitor.
    const third_tag = try world.createTag();
    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = left, .tag = third_tag } } }});
    try std.testing.expectEqual(@as(?world_mod.WindowId, null), world.focusedWindow());
    try std.testing.expectEqual(@as(?world_mod.OutputId, left), world.focusedOutput());
    // Removing the focused monitor falls back to another one.
    _ = try world.applyAtomically(&.{.{ .output = .{ .remove = left } }});
    try std.testing.expectEqual(@as(?world_mod.OutputId, right), world.focusedOutput());
}

test "sending the focused window to another monitor's tag keeps the monitor focused" {
    var world = world_mod.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: types.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const first_tag = try world.createTag();
    const second_tag = try world.createTag();
    const left = try world.createOutput(.{ .active_tag = first_tag, .bounds = rect, .usable = rect });
    _ = try world.createOutput(.{ .active_tag = second_tag, .bounds = rect, .usable = rect });
    const window = try world.createWindow(.{ .tag = first_tag });
    try world.manageWindow(window);
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = window } }});

    _ = try world.applyAtomically(&.{.{ .window = .{ .assign = .{ .window = window, .tag = second_tag } } }});
    try std.testing.expectEqual(@as(?world_mod.OutputId, left), world.focusedOutput());
    try std.testing.expectEqual(@as(?world_mod.WindowId, null), world.focusedWindow());
}

test "a tag is shown somewhere only while some output has it active" {
    var world = world_mod.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: types.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const shown = try world.createTag();
    const hidden = try world.createTag();
    const output = try world.createOutput(.{ .active_tag = shown, .bounds = rect, .usable = rect });
    try std.testing.expect(world.tagShownSomewhere(shown));
    try std.testing.expect(!world.tagShownSomewhere(hidden));
    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = output, .tag = hidden } } }});
    try std.testing.expect(world.tagShownSomewhere(hidden));
    try std.testing.expect(!world.tagShownSomewhere(shown));
}
