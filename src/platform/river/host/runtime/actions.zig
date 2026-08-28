//! Lower configured key actions against one explicitly scoped WM view.

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
    const focus_output = snapshot.firstOutput();
    for (action_indices) |action_index| {
        const action = config.bindings[action_index].action;
        switch (action) {
            .focus => |direction| if (focus_output) |output| try intents.append(.{ .focus_direction = .{ .output = output, .direction = direction } }),
            .swap => |direction| if (focus_output) |output| try intents.append(.{ .swap_direction = .{ .output = output, .direction = direction } }),
            .absorb => |direction| if (focus_output) |output| try intents.append(.{ .absorb = .{ .output = output, .direction = direction } }),
            .eject => if (focusedNode(snapshot)) |node| try intents.append(.{ .eject = node }),
            .expel => |direction| if (focusedNode(snapshot)) |node|
                try intents.append(.{ .expel = .{ .node = node, .direction = direction } }),
            .close_focused => if (focus_output) |output| if (snapshot.focusedWindow(output)) |window|
                try intents.append(.{ .close_window = window }),
            .toggle_float => if (focus_output) |output| if (snapshot.focusedWindow(output)) |window| {
                const current = snapshot.getWindow(window) orelse continue;
                try intents.append(.{ .transition_placement = .{
                    .window = window,
                    .transition = if (current.placement == .floating) .tiled else .floating,
                } });
            },
            .toggle_fullscreen => if (focus_output) |output| if (snapshot.focusedWindow(output)) |window| {
                const current = snapshot.getWindow(window) orelse continue;
                try intents.append(.{ .transition_placement = .{
                    .window = window,
                    .transition = if (current.placement == .fullscreen) .exit_fullscreen else .fullscreen,
                } });
            },
            .cycle_width => |step| if (focusedNode(snapshot)) |node_id| {
                const node = snapshot.getNode(node_id) orelse continue;
                try intents.append(.{ .cycle_column_width = .{ .column = node.column, .step = step } });
            },
            .toggle_split_tabbed => if (focusedParent(snapshot)) |parent| {
                try intents.append(.{ .set_container_mode = .{
                    .node = parent.id,
                    .mode = if (parent.mode == .tabbed) .split else .tabbed,
                    .axis = parent.axis,
                } });
            },
            .focus_tab => |step| if (focusedParent(snapshot)) |parent| {
                if (parent.mode != .tabbed or parent.children.items.len < 2) continue;
                const active = parent.active_child;
                const next = switch (step) {
                    .previous => if (active == 0) parent.children.items.len - 1 else active - 1,
                    .next => (active + 1) % parent.children.items.len,
                };
                try intents.append(.{ .set_active_tab = .{
                    .container = parent.id,
                    .child = parent.children.items[next].id,
                } });
            },
            .focus_tag => |ordinal| {
                const output = if (focus_output) |focused_output| if (snapshot.focusedWindow(focused_output)) |window|
                    (snapshot.getWindow(window) orelse continue).output orelse continue
                else
                    focused_output else continue;
                const tag = snapshot.tagAt(ordinal - 1) orelse continue;
                try intents.append(.{ .set_active_tag = .{ .output = output, .tag = tag } });
            },
            .send_to_tag => |ordinal| {
                const tag = snapshot.tagAt(ordinal - 1) orelse continue;
                const output = focus_output orelse continue;
                try intents.append(.{ .send_focused_window = .{ .source_output = output, .tag = tag } });
            },
            .spawn => |args| if (spawn) |hook| {
                try hook.run(hook.context, args);
            } else {
                @import("std").log.warn("configured spawn action has no host hook: {s}", .{args[0]});
            },
        }
    }
}

fn focusedNode(snapshot: *const script.Snapshot) ?wm.NodeId {
    const output = snapshot.firstOutput() orelse return null;
    const window = snapshot.focusedWindow(output) orelse return null;
    return snapshot.nodeForWindow(window);
}

fn focusedParent(snapshot: *const script.Snapshot) ?*const wm.Node {
    const node = snapshot.getNode(focusedNode(snapshot) orelse return null) orelse return null;
    return snapshot.getNode(node.parent orelse return null);
}
