//! Policy intent collection and translation for one manage cycle.

const std = @import("std");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");
const world = @import("whirlpool-river-live-world");
const configured_actions = @import("actions.zig");

/// Collect input, configured actions, and policy output into one atomic batch.
pub fn run(runtime: anytype, draft: anytype) !void {
    try consumeInput(runtime);

    var policy_intents = script.IntentBatch.init(runtime.allocator, runtime.options.max_intents);
    defer policy_intents.deinit();
    var action_batch: ?configured_actions.Layout = null;
    defer if (action_batch) |hook| finishActionBatch(hook, false);
    if (runtime.options.policy != null or runtime.configured_actions.items.len != 0 or runtime.layout_actions.items.len != 0) {
        var snapshot = runtime.adapter.worldView().view();
        var actions_valid = true;
        if ((runtime.configured_actions.items.len != 0 or runtime.layout_actions.items.len != 0) and
            runtime.options.layout != null and runtime.options.layout.?.action != null)
        {
            const hook = runtime.options.layout.?.action.?;
            if (hook.begin) |begin| {
                begin(hook.context) catch |err| {
                    std.log.warn("layout action batch failed to begin: {s}", .{@errorName(err)});
                    runtime.stats.policy_failures += 1;
                    actions_valid = false;
                };
                if (actions_valid) {
                    if (hook.finish == null) return error.IncompleteLayoutActionTransaction;
                    action_batch = hook;
                }
            }
        }
        if (actions_valid and runtime.configured_actions.items.len != 0)
            configured_actions.append(
                runtime.config_program.?,
                runtime.configured_actions.items,
                &snapshot,
                &policy_intents,
                runtime.options.spawn,
                if (runtime.options.layout) |layout| layout.action else null,
            ) catch |err| {
                std.log.warn("configured layout action failed: {s}", .{@errorName(err)});
                runtime.stats.policy_failures += 1;
                actions_valid = false;
            };
        runtime.configured_actions.clearRetainingCapacity();
        defer {
            for (runtime.layout_actions.items) |*action| action.deinit(runtime.allocator);
            runtime.layout_actions.clearRetainingCapacity();
        }
        if (actions_valid) if (runtime.options.layout) |layout| if (layout.action) |hook| {
            for (runtime.layout_actions.items) |action| {
                hook.run(hook.context, &snapshot, action.output, action.name, action.args, &policy_intents) catch |err| {
                    std.log.warn("layout action '{s}' failed: {s}", .{ action.name, @errorName(err) });
                    runtime.stats.policy_failures += 1;
                    actions_valid = false;
                    break;
                };
            }
        };
        if (runtime.options.policy) |hook| {
            var callback: script.Callback = .{};
            try callback.begin(.wm_policy, hook.budget);
            defer callback.end();
            runtime.stats.policy_callbacks += 1;
            hook.run(hook.context, &callback, &snapshot, &policy_intents) catch {
                runtime.stats.policy_failures += 1;
                policy_intents.clear();
                actions_valid = false;
            };
        }
        if (!actions_valid) {
            policy_intents.clear();
            if (action_batch) |hook| finishActionBatch(hook, false);
            action_batch = null;
        }
    }

    const total = runtime.queued_intents.count() + policy_intents.count();
    if (total == 0) {
        if (action_batch) |hook| try finishActionBatchChecked(hook, true);
        action_batch = null;
        return;
    }
    if (total > runtime.options.max_intents) {
        runtime.stats.policy_failures += 1;
        runtime.queued_intents.clear();
        if (action_batch) |hook| finishActionBatch(hook, false);
        action_batch = null;
        return;
    }
    const commands = try runtime.allocator.alloc(wm.Command, total);
    defer runtime.allocator.free(commands);
    const queued_count = try runtime.queued_intents.translate(commands);
    _ = try policy_intents.translate(commands[queued_count..]);
    _ = runtime.adapter.applyPolicyCommands(draft, commands) catch {
        runtime.stats.policy_failures += 1;
        runtime.queued_intents.clear();
        if (action_batch) |hook| finishActionBatch(hook, false);
        action_batch = null;
        return;
    };
    runtime.queued_intents.clear();
    std.debug.assert(runtime.queued_intents.count() == 0);
    if (action_batch) |hook| try finishActionBatchChecked(hook, true);
    action_batch = null;
}

fn finishActionBatchChecked(hook: configured_actions.Layout, commit: bool) !void {
    return (hook.finish orelse return error.IncompleteLayoutActionTransaction)(hook.context, commit);
}

fn finishActionBatch(hook: configured_actions.Layout, commit: bool) void {
    finishActionBatchChecked(hook, commit) catch |err|
        std.log.err("layout action batch failed to finish: {s}", .{@errorName(err)});
}

fn consumeInput(runtime: anytype) !void {
    const intents = try runtime.adapter.takeInputIntents();
    defer runtime.allocator.free(intents);
    for (intents) |intent| {
        const translated = try translateInput(runtime, intent) orelse continue;
        runtime.queued_intents.append(translated) catch |err| {
            runtime.queued_intents.clear();
            return err;
        };
    }
    std.debug.assert(runtime.queued_intents.count() <= runtime.options.max_intents);
}

fn translateInput(runtime: anytype, intent: world.input_intents.Intent) !?script.Intent {
    const live_window = intent.window orelse return null;
    const window = try runtime.adapter.objects.wmWindowId(live_window);
    const fact = runtime.adapter.worldView().getWindow(window) orelse return error.UnknownWindow;
    return switch (intent.action) {
        .focus => .{ .focus_window = window },
        .close => .{ .close_window = window },
        .toggle_floating => .{ .set_placement = .{
            .window = window,
            .placement = if (fact.placement == .floating) .tiled else .floating,
        } },
        .toggle_fullscreen => .{ .transition_placement = .{
            .window = window,
            .transition = if (fact.placement == .fullscreen) .exit_fullscreen else .fullscreen,
        } },
        .move => .{ .set_floating_geometry = .{
            .window = window,
            .geometry = try moveGeometry(fact.floating_geometry, .{ .x = intent.delta.x, .y = intent.delta.y }),
        } },
        .resize => .{ .set_floating_geometry = .{
            .window = window,
            .geometry = try resizeGeometry(
                fact.floating_geometry,
                try wm.ResizeEdges.fromBits(intent.edges orelse return null),
                .{ .x = intent.delta.x, .y = intent.delta.y },
            ),
        } },
    };
}

fn moveGeometry(rect: wm.Rect, delta: wm.Point) !wm.Rect {
    var result = rect;
    result.x = std.math.cast(i32, @as(i64, rect.x) + delta.x) orelse return error.GeometryOverflow;
    result.y = std.math.cast(i32, @as(i64, rect.y) + delta.y) orelse return error.GeometryOverflow;
    return result;
}

fn resizeGeometry(rect: wm.Rect, edges: wm.ResizeEdges, delta: wm.Point) !wm.Rect {
    var left: i64 = rect.x;
    var top: i64 = rect.y;
    var right = left + rect.width;
    var bottom = top + rect.height;
    if (edges.left) left += delta.x;
    if (edges.right) right += delta.x;
    if (edges.top) top += delta.y;
    if (edges.bottom) bottom += delta.y;
    if (right <= left) {
        if (edges.left) left = right - 1 else right = left + 1;
    }
    if (bottom <= top) {
        if (edges.top) top = bottom - 1 else bottom = top + 1;
    }
    return .{
        .x = std.math.cast(i32, left) orelse return error.GeometryOverflow,
        .y = std.math.cast(i32, top) orelse return error.GeometryOverflow,
        .width = std.math.cast(u32, right - left) orelse return error.GeometryOverflow,
        .height = std.math.cast(u32, bottom - top) orelse return error.GeometryOverflow,
    };
}
