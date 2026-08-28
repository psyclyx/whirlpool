//! Behavioral tests for the authoritative World transaction boundary.

const std = @import("std");
const types = @import("../types.zig");
const world_mod = @import("../world.zig");

const World = world_mod.World;
const WindowId = world_mod.WindowId;
const ColumnId = world_mod.ColumnId;
const NodeId = world_mod.NodeId;
const Rect = world_mod.Rect;
const ResizeEdges = world_mod.ResizeEdges;

test "world builds a generation-checked column tree with reciprocal links" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, column);
    try world.manageWindow(second, column);
    try world.validate();

    const root = world.getColumn(column).?.root.?;
    try std.testing.expectEqual(@as(usize, 2), world.getNode(root).?.children.items.len);
    try std.testing.expectEqual(root, world.getNode(world.getNode(root).?.children.items[0].id).?.parent.?);
    try std.testing.expectEqual(first, world.getNode(world.nodeForWindow(first).?).?.window.?);
}

test "failed command batches are atomic" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 640, .height = 480 },
        .usable = .{ .x = 0, .y = 0, .width = 640, .height = 480 },
    });
    const column = try world.createColumn(tag, .{});
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, column);
    const before_epoch = world.epoch();
    const before_nodes = world.liveNodeCount();
    try std.testing.expectError(error.UnknownNode, world.applyAtomically(&.{
        .{ .tree = .{ .wrap_node = .{ .node = world.nodeForWindow(first).?, .mode = .tabbed, .axis = .vertical } } },
        .{ .tree = .{ .unwrap_node = NodeId.fromParts(99, 1) } },
    }));
    try std.testing.expectEqual(before_epoch, world.epoch());
    try std.testing.expectEqual(before_nodes, world.liveNodeCount());
    try world.validate();
}

test "floating geometry commands move and resize only floating windows" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    const floating = try world.createWindow(.{
        .tag = tag,
        .output = output,
        .placement = .floating,
        .floating_geometry = .{ .x = 100, .y = 100, .width = 200, .height = 180 },
    });
    const tiled = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(floating, column);
    try world.manageWindow(tiled, column);

    _ = try world.applyAtomically(&.{.{ .geometry = .{ .move_floating = .{ .window = floating, .delta = .{ .x = 12, .y = -8 } } } }});
    try std.testing.expectEqual(
        Rect{ .x = 112, .y = 92, .width = 200, .height = 180 },
        world.getWindow(floating).?.floating_geometry,
    );
    _ = try world.applyAtomically(&.{.{ .geometry = .{ .resize_floating = .{
        .window = floating,
        .edges = try ResizeEdges.fromBits(5),
        .delta = .{ .x = 20, .y = 30 },
    } } }});
    try std.testing.expectEqual(
        Rect{ .x = 132, .y = 122, .width = 180, .height = 150 },
        world.getWindow(floating).?.floating_geometry,
    );
    try std.testing.expectError(error.NotFloating, world.applyAtomically(&.{.{ .geometry = .{ .move_floating = .{ .window = tiled, .delta = .{ .x = 1, .y = 1 } } } }}));
    try std.testing.expectError(error.InvalidResizeEdges, world.applyAtomically(&.{.{ .geometry = .{ .resize_floating = .{ .window = floating, .edges = .{}, .delta = .{ .x = 0, .y = 0 } } } }}));
    try world.validate();
}

test "floating geometry rejects undersized and overflowing atomic updates" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    const window = try world.createWindow(.{
        .tag = tag,
        .output = output,
        .placement = .floating,
        .floating_geometry = .{ .x = 100, .y = 100, .width = 50, .height = 50 },
    });
    try world.manageWindow(window, column);
    const before = world.getWindow(window).?.floating_geometry;
    const before_epoch = world.epoch();

    try std.testing.expectError(error.InvalidFloatingGeometry, world.applyAtomically(&.{
        .{ .geometry = .{ .resize_floating = .{
            .window = window,
            .edges = try ResizeEdges.fromBits(4),
            .delta = .{ .x = 50, .y = 0 },
        } } },
        .{ .geometry = .{ .move_floating = .{ .window = window, .delta = .{ .x = 10, .y = 10 } } } },
    }));
    try std.testing.expectEqual(before, world.getWindow(window).?.floating_geometry);
    try std.testing.expectEqual(before_epoch, world.epoch());
    try std.testing.expectError(error.InvalidFloatingGeometry, world.applyAtomically(&.{.{ .geometry = .{
        .move_floating = .{ .window = window, .delta = .{ .x = std.math.maxInt(i32), .y = 0 } },
    } }}));
    try std.testing.expectEqual(before, world.getWindow(window).?.floating_geometry);
    try world.validate();
}

test "stale node identities cannot mutate a reused slot" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 320, .height = 240 },
        .usable = .{ .x = 0, .y = 0, .width = 320, .height = 240 },
    });
    const column = try world.createColumn(tag, .{});
    const window = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(window, column);
    const node = world.nodeForWindow(window).?;
    _ = try world.applyAtomically(&.{.{ .window = .{ .destroy = window } }});
    try std.testing.expect(world.getNode(node) == null);
    const other = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(other, column);
    try std.testing.expect(world.getNode(node) == null);
    try world.validate();
}

test "mixed structural commands preserve invariants" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 1200, .height = 800 },
        .usable = .{ .x = 0, .y = 0, .width = 1200, .height = 800 },
    });
    const left = try world.createColumn(tag, .{ .width = 0.5 });
    const right = try world.createColumn(tag, .{ .width = 0.75 });
    var windows: [8]WindowId = undefined;
    for (&windows) |*window_id| {
        window_id.* = try world.createWindow(.{ .tag = tag, .output = output });
        try world.manageWindow(window_id.*, if (windows[0] == window_id.*) left else right);
    }
    _ = try world.applyAtomically(&.{.{ .tree = .{ .wrap_node = .{ .node = world.nodeForWindow(windows[0]).?, .mode = .tabbed, .axis = .vertical } } }});
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[2] } }});
    _ = try world.applyAtomically(&.{.{ .tree = .{ .move_node = .{ .node = world.nodeForWindow(windows[2]).?, .column = left } } }});
    _ = try world.applyAtomically(&.{.{ .tree = .{ .swap_nodes = .{ .first = world.nodeForWindow(windows[1]).?, .second = world.nodeForWindow(windows[3]).? } } }});
    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = output, .tag = tag } } }});
    try world.validate();
}

test "focus repair follows tag switches and focused destruction" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const first_tag = try world.createTag();
    const second_tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = first_tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const first_column = try world.createColumn(first_tag, .{});
    const second_column = try world.createColumn(second_tag, .{});
    const first = try world.createWindow(.{ .tag = first_tag, .output = output });
    const second = try world.createWindow(.{ .tag = first_tag, .output = output });
    try world.manageWindow(first, first_column);
    try world.manageWindow(second, first_column);
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = first } }});
    _ = try world.applyAtomically(&.{.{ .window = .{ .destroy = first } }});
    try world.validate();
    const repaired = world.getTag(first_tag).?.focused orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(second, world.getNode(repaired).?.window.?);

    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = output, .tag = second_tag } } }});
    try world.validate();
    try std.testing.expectEqual(@as(?NodeId, null), world.getTag(first_tag).?.focused);
    _ = try world.applyAtomically(&.{.{ .tree = .{ .move_node = .{ .node = world.nodeForWindow(second).?, .column = second_column } } }});
    try world.validate();
}

test "directional actions and structural moves keep the tree valid" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 1200, .height = 800 },
        .usable = .{ .x = 0, .y = 0, .width = 1200, .height = 800 },
    });
    const columns = [_]ColumnId{
        try world.createColumn(tag, .{ .width = 0.4 }),
        try world.createColumn(tag, .{ .width = 0.5 }),
        try world.createColumn(tag, .{ .width = 0.6 }),
    };
    var windows: [3]WindowId = undefined;
    for (&windows, 0..) |*window_id, index| {
        window_id.* = try world.createWindow(.{ .tag = tag, .output = output });
        try world.manageWindow(window_id.*, columns[index]);
    }

    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[1] } }});
    _ = try world.applyAtomically(&.{.{ .focus = .{ .direction = .{ .output = output, .direction = .left } } }});
    _ = try world.applyAtomically(&.{.{ .tree = .{ .swap_direction = .{ .output = output, .direction = .right } } }});
    try world.validate();

    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = windows[1] } }});
    _ = try world.applyAtomically(&.{.{ .tree = .{ .absorb = .{ .output = output, .direction = .right } } }});
    try world.validate();
    const absorbed = world.nodeForWindow(windows[0]).?;
    _ = try world.applyAtomically(&.{.{ .tree = .{ .eject = absorbed } }});
    try world.validate();
    _ = try world.applyAtomically(&.{.{ .tree = .{ .expel = .{ .node = absorbed, .direction = .right } } }});
    try world.validate();

    const moved_column = world.getNode(absorbed).?.column;
    _ = try world.applyAtomically(&.{.{ .geometry = .{ .resize_column = .{ .column = moved_column, .width = 0.9 } } }});
    _ = try world.applyAtomically(&.{.{ .geometry = .{ .cycle_column_width = .{ .column = moved_column, .step = .next } } }});
    _ = try world.applyAtomically(&.{.{ .geometry = .{ .set_camera_target = .{ .tag = tag, .target = 42 } } }});
    _ = try world.applyAtomically(&.{.{ .window = .{ .set_placement = .{ .window = windows[0], .placement = .floating } } }});
    try world.validate();
    _ = try world.applyAtomically(&.{.{ .window = .{ .set_placement = .{ .window = windows[0], .placement = .tiled } } }});
    try world.validate();
}

test "vertical absorb groups adjacent leaves without losing either window" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, column);
    try world.manageWindow(second, column);
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = second } }});
    _ = try world.applyAtomically(&.{.{ .tree = .{ .absorb = .{ .output = output, .direction = .up } } }});
    try world.validate();
    const first_node = world.getNode(world.nodeForWindow(first).?).?;
    const second_node = world.getNode(world.nodeForWindow(second).?).?;
    try std.testing.expectEqual(first_node.parent, second_node.parent);
    try std.testing.expect(first_node.parent != null);
    try std.testing.expectEqual(types.Axis.vertical, world.getNode(first_node.parent.?).?.axis);
}

test "output removal orphans windows and repairs focus" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 300 },
        .usable = .{ .x = 0, .y = 0, .width = 400, .height = 300 },
    });
    const column = try world.createColumn(tag, .{});
    const window = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(window, column);
    _ = try world.applyAtomically(&.{.{ .focus = .{ .window = window } }});
    _ = try world.applyAtomically(&.{.{ .output = .{ .remove = output } }});
    try std.testing.expect(world.getWindow(window).?.output == null);
    try std.testing.expect(world.getTag(tag).?.focused == null);
    _ = try world.applyAtomically(&.{.{ .window = .{ .destroy = window } }});
    _ = try world.applyAtomically(&.{.{ .tree = .{ .remove_column = column } }});
    _ = try world.applyAtomically(&.{.{ .tag = .{ .remove = tag } }});
    try world.validate();
}

test "marks are owned, unique, focusable, and included in snapshots" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    const first = try world.createWindow(.{ .tag = tag, .output = output });
    const second = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(first, column);
    try world.manageWindow(second, column);

    _ = try world.applyAtomically(&.{.{ .mark = .{ .set = .{ .window = first, .name = "editor" } } }});
    var snapshot = world.view();
    try std.testing.expectEqual(@as(usize, 1), snapshot.getWindow(first).?.marks.items.len);
    _ = try world.applyAtomically(&.{.{ .mark = .{ .set = .{ .window = second, .name = "editor" } } }});
    try std.testing.expectEqual(@as(usize, 0), world.getWindow(first).?.marks.items.len);
    try std.testing.expectEqual(@as(usize, 1), world.getWindow(second).?.marks.items.len);
    _ = try world.applyAtomically(&.{.{ .focus = .{ .mark = "editor" } }});
    try std.testing.expectEqual(second, world.getNode(world.getTag(tag).?.focused.?).?.window.?);
    _ = try world.applyAtomically(&.{.{ .mark = .{ .clear = .{ .window = second, .name = "editor" } } }});
    try std.testing.expectError(error.UnknownMark, world.applyAtomically(&.{.{ .focus = .{ .mark = "editor" } }}));
    try world.validate();
}

test "send and summon move a marked window across tags and outputs" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const first_tag = try world.createNamedTag("first");
    const second_tag = try world.createNamedTag("second");
    const first_output = try world.createOutput(.{
        .active_tag = first_tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const second_output = try world.createOutput(.{
        .active_tag = second_tag,
        .bounds = .{ .x = 800, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 800, .y = 0, .width = 800, .height = 600 },
    });
    const first_column = try world.createColumn(first_tag, .{});
    const second_column = try world.createColumn(second_tag, .{});
    const window = try world.createWindow(.{ .tag = first_tag, .output = first_output });
    try world.manageWindow(window, first_column);
    _ = try world.applyAtomically(&.{.{ .mark = .{ .set = .{ .window = window, .name = "terminal" } } }});

    _ = try world.applyAtomically(&.{.{ .transfer = .{ .send_window = .{ .window = window, .tag = second_tag, .output = second_output } } }});
    try std.testing.expectEqual(second_tag, world.getWindow(window).?.tag);
    try std.testing.expectEqual(second_output, world.getWindow(window).?.output.?);
    try std.testing.expectEqual(second_column, world.getNode(world.nodeForWindow(window).?).?.column);

    _ = try world.applyAtomically(&.{.{ .transfer = .{ .summon_window = .{ .window = window, .output = first_output } } }});
    try std.testing.expectEqual(first_tag, world.getWindow(window).?.tag);
    try std.testing.expectEqual(first_output, world.getWindow(window).?.output.?);
    try std.testing.expectEqual(window, world.getNode(world.getTag(first_tag).?.focused.?).?.window.?);

    _ = try world.applyAtomically(&.{.{ .transfer = .{ .summon_mark = .{ .name = "terminal", .output = second_output } } }});
    try std.testing.expectEqual(second_tag, world.getWindow(window).?.tag);
    try std.testing.expectEqual(second_output, world.getWindow(window).?.output.?);
    try world.validate();
}

test "tag toggle, output configuration, and persistence restore are typed" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const first_tag = try world.createNamedTag("one");
    const second_tag = try world.createNamedTag("two");
    const output = try world.createOutput(.{
        .active_tag = first_tag,
        .bounds = .{ .x = 0, .y = 0, .width = 1024, .height = 768 },
        .usable = .{ .x = 0, .y = 0, .width = 1024, .height = 768 },
    });
    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = output, .tag = second_tag } } }});
    _ = try world.applyAtomically(&.{.{ .tag = .{ .toggle = .{ .output = output, .tag = second_tag } } }});
    try std.testing.expectEqual(first_tag, world.getOutput(output).?.active_tag);
    _ = try world.applyAtomically(&.{
        .{ .output = .{ .configure = .{ .output = output, .configuration = .{ .enabled = true, .scale = 1.5, .transform = .ninety, .mode = .{ .width = 1920, .height = 1080 } } } } },
        .{ .tag = .{ .rename = .{ .tag = first_tag, .name = "work" } } },
    });

    var saved = try world.saveState();
    defer saved.deinit();
    _ = try world.applyAtomically(&.{
        .{ .tag = .{ .rename = .{ .tag = first_tag, .name = "mutated" } } },
        .{ .output = .{ .configure = .{ .output = output, .configuration = .{ .scale = 1 } } } },
    });
    try world.restoreState(&saved);
    try std.testing.expectEqualStrings("work", world.getTag(first_tag).?.name);
    try std.testing.expectEqual(@as(f32, 1.5), world.getOutput(output).?.configuration.scale);
    try std.testing.expectEqual(types.OutputTransform.ninety, world.getOutput(output).?.configuration.transform);
    try world.validate();
}
