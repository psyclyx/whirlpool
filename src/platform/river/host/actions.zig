//! Lower configured key actions against one explicitly scoped WM view.

const std = @import("std");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");

pub const Spawn = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, []const []const u8) anyerror!void,
};

pub fn append(
    config: *const script.config.Config,
    action_indices: []const usize,
    snapshot: *const script.Snapshot,
    intents: *script.IntentBatch,
    spawn: ?Spawn,
) !void {
    var runner = Runner{
        .config = config,
        .snapshot = snapshot,
        .intents = intents,
        .spawn = spawn,
        .focus_output = focusedOutput(snapshot),
    };
    try runner.appendAll(action_indices);
}

const Runner = struct {
    config: *const script.config.Config,
    snapshot: *const script.Snapshot,
    intents: *script.IntentBatch,
    spawn: ?Spawn,
    focus_output: ?wm.OutputId,

    fn appendAll(self: *Runner, indices: []const usize) !void {
        for (indices) |index| {
            std.debug.assert(index < self.config.bindings.len);
            try self.appendOne(self.config.bindings[index].action);
        }
    }

    fn appendOne(self: *Runner, action: script.config.Action) !void {
        switch (action) {
            .focus => |direction| if (self.focus_output) |output| try self.intents.append(.{ .focus_direction = .{ .output = output, .direction = direction } }),
            .swap => |direction| if (self.focus_output) |output| try self.intents.append(.{ .swap_direction = .{ .output = output, .direction = direction } }),
            .absorb => |direction| if (self.focus_output) |output| try self.intents.append(.{ .absorb = .{ .output = output, .direction = direction } }),
            .eject => if (focusedNode(self.snapshot)) |node| try self.intents.append(.{ .eject = node }),
            .expel => |direction| if (focusedNode(self.snapshot)) |node| try self.intents.append(.{ .expel = .{ .node = node, .direction = direction } }),
            .close_focused => if (self.focusedWindow()) |window| try self.intents.append(.{ .close_window = window }),
            .toggle_float => try self.togglePlacement(.floating, .tiled, .floating),
            .toggle_fullscreen => try self.togglePlacement(.fullscreen, .exit_fullscreen, .fullscreen),
            .cycle_width => |step| if (focusedNode(self.snapshot)) |node_id| {
                const node = self.snapshot.getNode(node_id) orelse return;
                try self.intents.append(.{ .cycle_column_width = .{ .column = node.column, .step = step } });
            },
            .toggle_split_tabbed => try self.toggleContainerMode(),
            .focus_tab => |step| try self.focusTab(step),
            .focus_output => |step| try self.focusOutput(step),
            .focus_tag => |ordinal| try self.focusTag(ordinal),
            .send_to_tag => |ordinal| try self.sendToTag(ordinal),
            .spawn => |args| try self.spawnCommand(args),
        }
    }

    fn focusedWindow(self: *const Runner) ?wm.WindowId {
        const output = self.focus_output orelse return null;
        return self.snapshot.focusedWindow(output);
    }

    fn togglePlacement(self: *Runner, current: wm.Placement, otherwise: wm.PlacementTransition, selected: wm.PlacementTransition) !void {
        const window = self.focusedWindow() orelse return;
        const state = self.snapshot.getWindow(window) orelse return;
        try self.intents.append(.{ .transition_placement = .{
            .window = window,
            .transition = if (state.placement == current) otherwise else selected,
        } });
    }

    fn toggleContainerMode(self: *Runner) !void {
        const parent = focusedParent(self.snapshot) orelse return;
        try self.intents.append(.{ .set_container_mode = .{
            .node = parent.id,
            .mode = if (parent.mode == .tabbed) .split else .tabbed,
            .axis = parent.axis,
        } });
    }

    fn focusTab(self: *Runner, step: script.config.TabStep) !void {
        const parent = focusedParent(self.snapshot) orelse return;
        if (parent.mode != .tabbed or parent.children.items.len < 2) return;
        std.debug.assert(parent.active_child < parent.children.items.len);
        const next = switch (step) {
            .previous => if (parent.active_child == 0) parent.children.items.len - 1 else parent.active_child - 1,
            .next => (parent.active_child + 1) % parent.children.items.len,
        };
        try self.intents.append(.{ .set_active_tab = .{
            .container = parent.id,
            .child = parent.children.items[next].id,
        } });
    }

    fn focusOutput(self: *Runner, step: script.config.TabStep) !void {
        const count = self.snapshot.liveOutputCount();
        if (count < 2) return;
        const current = self.focus_output orelse return;
        var current_index: usize = 0;
        while (current_index < count and self.snapshot.outputAt(current_index) != current) : (current_index += 1) {}
        if (current_index == count) return;
        const next_index = switch (step) {
            .previous => if (current_index == 0) count - 1 else current_index - 1,
            .next => (current_index + 1) % count,
        };
        const output = self.snapshot.outputAt(next_index) orelse return;
        self.focus_output = output;
        if (self.snapshot.focusedWindow(output)) |window| try self.intents.append(.{ .focus_window = window });
    }

    fn focusTag(self: *Runner, ordinal: u8) !void {
        std.debug.assert(ordinal > 0);
        const output = self.focusedWindowOutput() orelse return;
        const tag = self.snapshot.tagAt(ordinal - 1) orelse return;
        try self.intents.append(.{ .set_active_tag = .{ .output = output, .tag = tag } });
    }

    fn sendToTag(self: *Runner, ordinal: u8) !void {
        std.debug.assert(ordinal > 0);
        const output = self.focus_output orelse return;
        const tag = self.snapshot.tagAt(ordinal - 1) orelse return;
        try self.intents.append(.{ .send_focused_window = .{ .source_output = output, .tag = tag } });
    }

    fn focusedWindowOutput(self: *const Runner) ?wm.OutputId {
        const focused_output = self.focus_output orelse return null;
        const window = self.snapshot.focusedWindow(focused_output) orelse return focused_output;
        return (self.snapshot.getWindow(window) orelse return null).output;
    }

    fn spawnCommand(self: *Runner, args: []const []const u8) !void {
        std.debug.assert(args.len > 0);
        if (self.spawn) |hook| return hook.run(hook.context, args);
        std.log.warn("configured spawn action has no host hook: {s}", .{args[0]});
    }
};

fn focusedNode(snapshot: *const script.Snapshot) ?wm.NodeId {
    const output = focusedOutput(snapshot) orelse return null;
    const window = snapshot.focusedWindow(output) orelse return null;
    return snapshot.nodeForWindow(window);
}

fn focusedOutput(snapshot: *const script.Snapshot) ?wm.OutputId {
    var result = snapshot.firstOutput();
    var best_serial: u64 = 0;
    var output_index: usize = 0;
    while (snapshot.outputAt(output_index)) |output| : (output_index += 1) {
        const window_id = snapshot.focusedWindow(output) orelse continue;
        const window = snapshot.getWindow(window_id) orelse continue;
        if (result == null or window.focus_serial > best_serial) {
            result = output;
            best_serial = window.focus_serial;
        }
    }
    return result;
}

fn focusedParent(snapshot: *const script.Snapshot) ?*const wm.Node {
    const node = snapshot.getNode(focusedNode(snapshot) orelse return null) orelse return null;
    return snapshot.getNode(node.parent orelse return null);
}
