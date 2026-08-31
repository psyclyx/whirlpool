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
    if (runtime.options.policy != null or runtime.configured_actions.items.len != 0) {
        var snapshot = runtime.adapter.worldView().view();
        if (runtime.configured_actions.items.len != 0)
            try configured_actions.append(
                runtime.config_program.?,
                runtime.configured_actions.items,
                &snapshot,
                &policy_intents,
                runtime.options.spawn,
                if (runtime.options.layout) |layout| layout.action else null,
            );
        runtime.configured_actions.clearRetainingCapacity();
        if (runtime.options.policy) |hook| {
            var callback: script.Callback = .{};
            try callback.begin(.wm_policy, hook.budget);
            defer callback.end();
            runtime.stats.policy_callbacks += 1;
            hook.run(hook.context, &callback, &snapshot, &policy_intents) catch {
                runtime.stats.policy_failures += 1;
                policy_intents.clear();
            };
        }
    }

    const total = runtime.queued_intents.count() + policy_intents.count();
    if (total == 0) return;
    if (total > runtime.options.max_intents) {
        runtime.stats.policy_failures += 1;
        runtime.queued_intents.clear();
        return;
    }
    const commands = try runtime.allocator.alloc(wm.Command, total);
    defer runtime.allocator.free(commands);
    const queued_count = try runtime.queued_intents.translate(commands);
    _ = try policy_intents.translate(commands[queued_count..]);
    _ = runtime.adapter.applyPolicyCommands(draft, commands) catch {
        runtime.stats.policy_failures += 1;
        runtime.queued_intents.clear();
        return;
    };
    runtime.queued_intents.clear();
    std.debug.assert(runtime.queued_intents.count() == 0);
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
    const output = (runtime.adapter.worldView().getWindow(window) orelse return error.UnknownWindow).output orelse return null;
    return switch (intent.action) {
        .focus => .{ .focus_window = window },
        .close => .{ .close_window = window },
        .toggle_floating => .{ .transition_placement = .{ .window = window, .transition = .floating } },
        .toggle_fullscreen => .{ .transition_placement = .{ .window = window, .transition = .fullscreen } },
        .next_column => .{ .focus_direction = .{ .output = output, .direction = .right } },
        .previous_column => .{ .focus_direction = .{ .output = output, .direction = .left } },
        .move => .{ .move_floating = .{ .window = window, .delta = .{ .x = intent.delta.x, .y = intent.delta.y } } },
        .resize => .{ .resize_floating = .{
            .window = window,
            .edges = try wm.ResizeEdges.fromBits(intent.edges orelse return null),
            .delta = .{ .x = intent.delta.x, .y = intent.delta.y },
        } },
    };
}
