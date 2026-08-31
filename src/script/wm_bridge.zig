//! The bounded, protocol-free Lua policy boundary for the WM.
//!
//! A callback borrows an immutable view of the authoritative WM world.
//! An IntentBatch owns only script policy values and can lower them into a
//! caller-provided slice of semantic WM commands.  Neither side contains a
//! Wayland proxy, graphics handle, Lua value, or pointer into the live World.

const std = @import("std");
const wm = @import("whirlpool-wm");

pub const Snapshot = wm.WorldView;

/// The script-facing intent set is deliberately smaller than wm.Command.
/// Each variant is a semantic request and contains only public WM values.
pub const Intent = union(enum) {
    focus_window: wm.WindowId,
    focus_direction: struct { output: wm.OutputId, direction: wm.Direction },
    swap_direction: struct { output: wm.OutputId, direction: wm.Direction },
    absorb: struct { output: wm.OutputId, direction: wm.Direction },
    eject: wm.NodeId,
    expel: struct { node: wm.NodeId, direction: wm.Direction },
    close_window: wm.WindowId,
    destroy_window: wm.WindowId,
    move_node: struct { node: wm.NodeId, column: wm.ColumnId },
    resize_column: struct { column: wm.ColumnId, width: f32 },
    cycle_column_width: struct { column: wm.ColumnId, step: wm.ColumnWidthStep },
    set_container_mode: struct { node: wm.NodeId, mode: wm.ContainerMode, axis: wm.Axis },
    set_active_tab: struct { container: wm.NodeId, child: wm.NodeId },
    resize_split: struct { split: wm.NodeId, child: wm.NodeId, weight: f32 },
    move_floating: struct { window: wm.WindowId, delta: wm.Point },
    resize_floating: struct { window: wm.WindowId, edges: wm.ResizeEdges, delta: wm.Point },
    set_camera_target: struct { tag: wm.TagId, target: f32 },
    set_active_tag: struct { output: wm.OutputId, tag: wm.TagId },
    send_focused_window: struct { source_output: wm.OutputId, tag: wm.TagId, output: ?wm.OutputId = null },
    set_window_output: struct { window: wm.WindowId, output: ?wm.OutputId },
    set_placement: struct { window: wm.WindowId, placement: wm.Placement },
    transition_placement: struct {
        window: wm.WindowId,
        transition: wm.types.PlacementTransition,
    },

    pub fn toCommand(self: Intent) wm.Command {
        return switch (self) {
            .focus_window => |id| .{ .focus = .{ .window = id } },
            .focus_direction => |value| .{ .focus = .{ .direction = .{ .output = value.output, .direction = value.direction } } },
            .swap_direction => |value| .{ .tree = .{ .swap_direction = .{ .output = value.output, .direction = value.direction } } },
            .absorb => |value| .{ .tree = .{ .absorb = .{ .output = value.output, .direction = value.direction } } },
            .eject => |node| .{ .tree = .{ .eject = node } },
            .expel => |value| .{ .tree = .{ .expel = .{ .node = value.node, .direction = value.direction } } },
            .close_window => |id| .{ .window = .{ .begin_close = id } },
            .destroy_window => |id| .{ .window = .{ .destroy = id } },
            .move_node => |value| .{ .tree = .{ .move_node = .{ .node = value.node, .column = value.column } } },
            .resize_column => |value| .{ .geometry = .{ .resize_column = .{ .column = value.column, .width = value.width } } },
            .cycle_column_width => |value| .{ .geometry = .{ .cycle_column_width = .{ .column = value.column, .step = value.step } } },
            .set_container_mode => |value| .{ .tree = .{ .set_container_mode = .{ .node = value.node, .mode = value.mode, .axis = value.axis } } },
            .set_active_tab => |value| .{ .tree = .{ .set_active_tab = .{ .container = value.container, .child = value.child } } },
            .resize_split => |value| .{ .geometry = .{ .resize_split = .{ .split = value.split, .child = value.child, .weight = value.weight } } },
            .move_floating => |value| .{ .geometry = .{ .move_floating = .{ .window = value.window, .delta = value.delta } } },
            .resize_floating => |value| .{ .geometry = .{ .resize_floating = .{ .window = value.window, .edges = value.edges, .delta = value.delta } } },
            .set_camera_target => |value| .{ .geometry = .{ .set_camera_target = .{ .tag = value.tag, .target = value.target } } },
            .set_active_tag => |value| .{ .tag = .{ .activate = .{ .output = value.output, .tag = value.tag } } },
            .send_focused_window => |value| .{ .transfer = .{ .send_focused = .{ .source_output = value.source_output, .tag = value.tag, .output = value.output } } },
            .set_window_output => |value| .{ .window = .{ .set_output = .{ .window = value.window, .output = value.output } } },
            .set_placement => |value| .{ .window = .{ .set_placement = .{ .window = value.window, .placement = value.placement } } },
            .transition_placement => |value| .{ .window = .{ .transition_placement = .{ .window = value.window, .transition = value.transition } } },
        };
    }
};

pub const IntentBatch = struct {
    intents: std.ArrayList(Intent) = .empty,
    allocator: std.mem.Allocator,
    limit: usize,

    pub fn init(allocator: std.mem.Allocator, limit: usize) IntentBatch {
        return .{ .allocator = allocator, .limit = limit };
    }

    pub fn deinit(self: *IntentBatch) void {
        self.intents.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const IntentBatch) usize {
        return self.intents.items.len;
    }

    pub fn append(self: *IntentBatch, intent: Intent) !void {
        if (self.intents.items.len >= self.limit) return error.IntentLimitExceeded;
        try self.intents.append(self.allocator, intent);
    }

    pub fn clear(self: *IntentBatch) void {
        self.intents.clearRetainingCapacity();
    }

    /// Lower intents without allocating.  The host owns the command storage,
    /// making the output bound and allocation visible at the call site.
    pub fn translate(self: *const IntentBatch, destination: []wm.Command) !usize {
        if (destination.len < self.intents.items.len) return error.CommandBufferTooSmall;
        for (self.intents.items, 0..) |intent, index| {
            destination[index] = intent.toCommand();
        }
        return self.intents.items.len;
    }
};

test "policy callbacks borrow the authoritative world without cloning it" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();

    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    const window = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(window, column);
    const epoch = world.epoch();

    const snapshot = world.view();
    try std.testing.expectEqual(epoch, snapshot.epoch());
    try std.testing.expect(snapshot.getWindow(window) != null);
    try snapshot.validate();
}

test "intent batches are bounded and lower to semantic WM commands" {
    var batch = IntentBatch.init(std.testing.allocator, 2);
    defer batch.deinit();

    const window = wm.WindowId.fromParts(4, 2);
    try batch.append(.{ .focus_window = window });
    try batch.append(.{ .close_window = window });
    try std.testing.expectError(error.IntentLimitExceeded, batch.append(.{ .destroy_window = window }));

    var commands: [2]wm.Command = undefined;
    try std.testing.expectEqual(@as(usize, 2), try batch.translate(&commands));
    try std.testing.expectEqual(window, commands[0].focus.window);
    try std.testing.expectEqual(window, commands[1].window.begin_close);

    var too_small: [1]wm.Command = undefined;
    try std.testing.expectError(error.CommandBufferTooSmall, batch.translate(&too_small));
}

test "intent translation does not validate or mutate the WM" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const epoch = world.epoch();

    var batch = IntentBatch.init(std.testing.allocator, 1);
    defer batch.deinit();
    try batch.append(.{ .focus_window = wm.WindowId.fromParts(99, 1) });
    var commands: [1]wm.Command = undefined;
    _ = try batch.translate(&commands);

    try std.testing.expectEqual(epoch, world.epoch());
    try world.validate();
}
