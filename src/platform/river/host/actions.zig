//! Lower configured key actions against one explicitly scoped WM view.

const std = @import("std");
const script = @import("whirlpool-script");
const wm = @import("whirlpool-wm");

pub const Spawn = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, []const []const u8) anyerror!void,
};

/// Invoke one opaque configured action in the retained layout controller.
pub const Layout = struct {
    context: ?*anyopaque = null,
    begin: ?*const fn (?*anyopaque) anyerror!void = null,
    run: *const fn (
        ?*anyopaque,
        *const script.Snapshot,
        wm.OutputId,
        []const u8,
        []const []const u8,
        *script.IntentBatch,
    ) anyerror!void,
    finish: ?*const fn (?*anyopaque, bool) anyerror!void = null,
};

pub fn append(
    config: *const script.config.Config,
    action_indices: []const usize,
    snapshot: *const script.Snapshot,
    intents: *script.IntentBatch,
    spawn: ?Spawn,
    layout: ?Layout,
) !void {
    var runner = Runner{
        .config = config,
        .snapshot = snapshot,
        .intents = intents,
        .spawn = spawn,
        .layout = layout,
        .focus_output = focusedOutput(snapshot),
    };
    try runner.appendAll(action_indices);
}

const Runner = struct {
    config: *const script.config.Config,
    snapshot: *const script.Snapshot,
    intents: *script.IntentBatch,
    spawn: ?Spawn,
    layout: ?Layout,
    focus_output: ?wm.OutputId,

    fn appendAll(self: *Runner, indices: []const usize) !void {
        for (indices) |index| {
            std.debug.assert(index < self.config.bindings.len);
            try self.appendOne(self.config.bindings[index].action);
        }
    }

    fn appendOne(self: *Runner, action: script.config.Action) !void {
        switch (action) {
            .layout => |value| if (self.focus_output) |output| if (self.layout) |hook|
                try hook.run(hook.context, self.snapshot, output, value.name, value.args, self.intents),
            .enter_mode => {},
            .spawn => |args| try self.spawnCommand(args),
        }
    }

    fn spawnCommand(self: *Runner, args: []const []const u8) !void {
        std.debug.assert(args.len > 0);
        if (self.spawn) |hook| {
            hook.run(hook.context, args) catch |err| {
                std.log.warn("configured command '{s}' failed to start: {s}", .{ args[0], @errorName(err) });
            };
            return;
        }
        std.log.warn("configured spawn action has no host hook: {s}", .{args[0]});
    }
};

fn focusedOutput(snapshot: *const script.Snapshot) ?wm.OutputId {
    return snapshot.focusedOutput();
}

test "configured spawn failures do not escape into the compositor loop" {
    const FailingSpawn = struct {
        fn run(_: ?*anyopaque, _: []const []const u8) !void {
            return error.FileNotFound;
        }
    };

    var runner: Runner = undefined;
    runner.spawn = .{ .run = FailingSpawn.run };
    try runner.spawnCommand(&.{"missing-command"});
}
