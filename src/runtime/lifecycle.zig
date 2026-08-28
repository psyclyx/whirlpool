//! Runtime process lifecycle independent of the process and socket owners.
//!
//! The state machine records requests and observations; it does not start a
//! process, reload a Lua program, or hide a transport failure. The concrete
//! runtime reports those effects back as events after it has performed them.

const std = @import("std");

pub const State = enum {
    stopped,
    starting,
    running,
    reload_pending,
    reloading,
    stopping,
    failed,
};

pub const Failure = enum {
    startup,
    reload,
    transport,
    unexpected_exit,
};

pub const Event = union(enum) {
    start_requested,
    started,
    reload_requested,
    reload_started,
    reload_succeeded,
    stop_requested,
    stopped,
    failed: Failure,
};

pub const Snapshot = struct {
    state: State,
    revision: u64,
    launches: u64,
    reloads: u64,
    last_failure: ?Failure,
};

pub const Controller = struct {
    state: State = .stopped,
    revision: u64 = 0,
    launches: u64 = 0,
    reloads: u64 = 0,
    last_failure: ?Failure = null,

    /// Apply one observed lifecycle edge. Invalid edges leave the controller
    /// untouched, so a rejected event cannot partially advance introspection.
    pub fn observe(self: *Controller, event: Event) error{InvalidTransition}!void {
        const next = try transition(self.state, event);
        self.state = next;
        self.revision += 1;

        switch (event) {
            .start_requested => self.launches += 1,
            .reload_succeeded => self.reloads += 1,
            .failed => |failure| self.last_failure = failure,
            else => {},
        }
    }

    pub fn snapshot(self: *const Controller) Snapshot {
        return .{
            .state = self.state,
            .revision = self.revision,
            .launches = self.launches,
            .reloads = self.reloads,
            .last_failure = self.last_failure,
        };
    }
};

fn transition(state: State, event: Event) error{InvalidTransition}!State {
    return switch (state) {
        .stopped => switch (event) {
            .start_requested => .starting,
            else => error.InvalidTransition,
        },
        .starting => switch (event) {
            .started => .running,
            .failed => |failure| if (failure == .startup or failure == .transport or failure == .unexpected_exit)
                .failed
            else
                error.InvalidTransition,
            .stop_requested => .stopping,
            else => error.InvalidTransition,
        },
        .running => switch (event) {
            .reload_requested => .reload_pending,
            .stop_requested => .stopping,
            .failed => |failure| if (failure == .transport or failure == .unexpected_exit)
                .failed
            else
                error.InvalidTransition,
            else => error.InvalidTransition,
        },
        .reload_pending => switch (event) {
            .reload_started => .reloading,
            .stop_requested => .stopping,
            .failed => |failure| if (failure == .reload or failure == .transport or failure == .unexpected_exit)
                .failed
            else
                error.InvalidTransition,
            else => error.InvalidTransition,
        },
        .reloading => switch (event) {
            .reload_succeeded => .running,
            .stop_requested => .stopping,
            .failed => |failure| if (failure == .reload or failure == .transport or failure == .unexpected_exit)
                .failed
            else
                error.InvalidTransition,
            else => error.InvalidTransition,
        },
        .stopping => switch (event) {
            .stopped => .stopped,
            .failed => |failure| if (failure == .transport or failure == .unexpected_exit)
                .failed
            else
                error.InvalidTransition,
            else => error.InvalidTransition,
        },
        .failed => switch (event) {
            .start_requested => .starting,
            else => error.InvalidTransition,
        },
    };
}

test "lifecycle requires observed startup and reload completion" {
    var controller: Controller = .{};

    try controller.observe(.start_requested);
    try controller.observe(.started);
    try controller.observe(.reload_requested);
    try std.testing.expectError(error.InvalidTransition, controller.observe(.reload_requested));
    try controller.observe(.reload_started);
    try controller.observe(.reload_succeeded);

    const snapshot = controller.snapshot();
    try std.testing.expectEqual(State.running, snapshot.state);
    try std.testing.expectEqual(@as(u64, 1), snapshot.launches);
    try std.testing.expectEqual(@as(u64, 1), snapshot.reloads);
    try std.testing.expectEqual(@as(u64, 5), snapshot.revision);
}

test "failed lifecycle edges are visible and restart is explicit" {
    var controller: Controller = .{};
    try controller.observe(.start_requested);
    try controller.observe(.{ .failed = .startup });
    try std.testing.expectEqual(Failure.startup, controller.snapshot().last_failure.?);
    try std.testing.expectError(error.InvalidTransition, controller.observe(.started));

    try controller.observe(.start_requested);
    try controller.observe(.started);
    try controller.observe(.stop_requested);
    try controller.observe(.stopped);
    try std.testing.expectEqual(State.stopped, controller.state);
}

test "stop may interrupt a pending or active reload" {
    var controller: Controller = .{};
    try controller.observe(.start_requested);
    try controller.observe(.started);
    try controller.observe(.reload_requested);
    try controller.observe(.stop_requested);
    try controller.observe(.stopped);
    try std.testing.expectEqual(State.stopped, controller.state);
}
