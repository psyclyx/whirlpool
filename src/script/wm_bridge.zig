//! Bounded Lua boundary for generic compositor resource effects.

const std = @import("std");
const wm = @import("whirlpool-wm");

pub const Snapshot = wm.WorldView;

/// Layout and shell relationships never cross this boundary. Lua resolves its
/// retained model into effects on concrete windows, tags, and outputs.
pub const Intent = union(enum) {
    focus_window: wm.WindowId,
    focus_output: wm.OutputId,
    clear_focus,
    close_window: wm.WindowId,
    assign_window: struct { window: wm.WindowId, tag: wm.TagId },
    set_placement: struct { window: wm.WindowId, placement: wm.Placement },
    transition_placement: struct { window: wm.WindowId, transition: wm.PlacementTransition },
    set_floating_geometry: struct { window: wm.WindowId, geometry: wm.Rect },
    set_active_tag: struct { output: wm.OutputId, tag: wm.TagId },

    pub fn toCommand(self: Intent) wm.Command {
        return switch (self) {
            .focus_window => |window| .{ .focus = .{ .window = window } },
            .focus_output => |output| .{ .focus = .{ .output = output } },
            .clear_focus => .{ .focus = .clear },
            .close_window => |window| .{ .window = .{ .begin_close = window } },
            .assign_window => |value| .{ .window = .{ .assign = .{
                .window = value.window,
                .tag = value.tag,
            } } },
            .set_placement => |value| .{ .window = .{ .set_placement = .{
                .window = value.window,
                .placement = value.placement,
            } } },
            .transition_placement => |value| .{ .window = .{ .transition_placement = .{
                .window = value.window,
                .transition = value.transition,
            } } },
            .set_floating_geometry => |value| .{ .window = .{ .set_floating_geometry = .{
                .window = value.window,
                .geometry = value.geometry,
            } } },
            .set_active_tag => |value| .{ .tag = .{ .activate = .{
                .output = value.output,
                .tag = value.tag,
            } } },
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

    pub fn translate(self: *const IntentBatch, destination: []wm.Command) !usize {
        if (destination.len < self.intents.items.len) return error.CommandBufferTooSmall;
        for (self.intents.items, 0..) |intent, index| destination[index] = intent.toCommand();
        return self.intents.items.len;
    }
};

test "intent batches lower only concrete leaf effects" {
    var batch = IntentBatch.init(std.testing.allocator, 2);
    defer batch.deinit();
    const window = wm.WindowId.fromParts(4, 2);
    try batch.append(.{ .focus_window = window });
    try batch.append(.{ .close_window = window });
    try std.testing.expectError(error.IntentLimitExceeded, batch.append(.clear_focus));
    var commands: [2]wm.Command = undefined;
    try std.testing.expectEqual(@as(usize, 2), try batch.translate(&commands));
    try std.testing.expectEqual(window, commands[0].focus.window);
    try std.testing.expectEqual(window, commands[1].window.begin_close);
}

test "snapshot exposes flat windows without layout identities" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    _ = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const window = try world.createWindow(.{ .tag = tag });
    try world.manageWindow(window);
    const snapshot = world.view();
    try std.testing.expectEqual(window, snapshot.windowAt(0).?);
    try snapshot.validate();
}
