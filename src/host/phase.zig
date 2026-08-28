//! river_window_manager_v1 manage/render sequence state machine.

const std = @import("std");

pub const Phase = enum {
    idle,
    managing,
    awaiting_render,
    rendering,
};

pub const Terminal = enum {
    active,
    unavailable,
    finished,
    destroyed,
};

pub const Sequence = struct {
    phase: Phase = .idle,
    terminal: Terminal = .active,
    stop_requested: bool = false,
    server_event_seen: bool = false,
    manage_dirty_requested: bool = false,

    pub fn noteServerEvent(self: *Sequence) !void {
        try self.requireActive();
        self.server_event_seen = true;
    }

    pub fn onManageStart(self: *Sequence) !void {
        try self.requireActive();
        if (self.phase != .idle) return error.InvalidSequence;
        self.server_event_seen = true;
        self.manage_dirty_requested = false;
        self.phase = .managing;
    }

    pub fn onRenderStart(self: *Sequence) !void {
        try self.requireActive();
        if (self.phase != .idle and self.phase != .awaiting_render) {
            return error.InvalidSequence;
        }
        self.server_event_seen = true;
        self.phase = .rendering;
    }

    pub fn completeManage(self: *Sequence) !void {
        try self.requireActive();
        if (self.phase != .managing) return error.InvalidSequence;
        self.phase = .awaiting_render;
    }

    pub fn completeRender(self: *Sequence) !void {
        try self.requireActive();
        if (self.phase != .rendering) return error.InvalidSequence;
        self.phase = .idle;
    }

    pub fn requestManageDirty(self: *Sequence) !void {
        try self.requireActive();
        if (self.stop_requested) return error.Stopping;
        self.manage_dirty_requested = true;
    }

    pub fn requestStop(self: *Sequence) !void {
        try self.requireActive();
        if (self.stop_requested) return error.Stopping;
        self.stop_requested = true;
    }

    pub fn onUnavailable(self: *Sequence) !void {
        try self.requireActive();
        if (self.server_event_seen or self.phase != .idle or self.stop_requested) {
            return error.InvalidSequence;
        }
        self.server_event_seen = true;
        self.terminal = .unavailable;
    }

    pub fn onFinished(self: *Sequence) !void {
        try self.requireActive();
        if (!self.stop_requested or self.phase == .managing or self.phase == .rendering) {
            return error.InvalidSequence;
        }
        self.server_event_seen = true;
        self.terminal = .finished;
    }

    pub fn destroy(self: *Sequence) !void {
        if (self.terminal != .unavailable and self.terminal != .finished) {
            return error.DestroyBeforeFinished;
        }
        self.terminal = .destroyed;
    }

    pub fn requireManagement(self: *const Sequence) !void {
        try self.requireActive();
        if (self.phase != .managing) return error.InvalidRequestPhase;
    }

    pub fn requireRendering(self: *const Sequence) !void {
        try self.requireActive();
        if (self.phase != .managing and self.phase != .rendering) {
            return error.InvalidRequestPhase;
        }
    }

    fn requireActive(self: *const Sequence) !void {
        if (self.terminal != .active) return error.ProtocolClosed;
    }
};

/// Start a manage sequence, run one handler, and attempt manage_finish exactly
/// once even if the handler fails. A finish transport failure takes precedence
/// because the compositor cannot legally make progress without it.
pub fn runManage(
    sequence: *Sequence,
    sink: anytype,
    context: anytype,
    comptime handler: fn (@TypeOf(context), *Sequence, @TypeOf(sink)) anyerror!void,
) anyerror!void {
    try sequence.onManageStart();
    var handled_error: ?anyerror = null;
    handler(context, sequence, sink) catch |err| {
        handled_error = err;
    };
    try sink.finishManage(sequence);
    if (handled_error) |err| return err;
}

/// Render counterpart to runManage. The handler is never retried and the sink
/// receives one render_finish attempt on every handled path.
pub fn runRender(
    sequence: *Sequence,
    sink: anytype,
    context: anytype,
    comptime handler: fn (@TypeOf(context), *Sequence, @TypeOf(sink)) anyerror!void,
) anyerror!void {
    try sequence.onRenderStart();
    var handled_error: ?anyerror = null;
    handler(context, sequence, sink) catch |err| {
        handled_error = err;
    };
    try sink.finishRender(sequence);
    if (handled_error) |err| return err;
}

test "manager termination requires stop, finished, then destroy" {
    var sequence: Sequence = .{};
    try std.testing.expectError(error.InvalidSequence, sequence.onFinished());
    try sequence.requestStop();
    try sequence.onFinished();
    try sequence.destroy();
    try std.testing.expectEqual(Terminal.destroyed, sequence.terminal);
}

test "finished may cancel the render River had not started" {
    var sequence: Sequence = .{};
    try sequence.onManageStart();
    try sequence.requestStop();
    try std.testing.expectError(error.InvalidSequence, sequence.onFinished());
    try sequence.completeManage();
    try sequence.onFinished();
    try std.testing.expectEqual(Terminal.finished, sequence.terminal);
}

test "manage must be followed by render while consecutive renders are legal" {
    var sequence: Sequence = .{};
    try sequence.onManageStart();
    try sequence.completeManage();
    try std.testing.expectError(error.InvalidSequence, sequence.onManageStart());
    try sequence.onRenderStart();
    try sequence.completeRender();
    try sequence.onRenderStart();
    try sequence.completeRender();
}

test "request classes expose only River-legal phases" {
    var sequence: Sequence = .{};
    try std.testing.expectError(error.InvalidRequestPhase, sequence.requireManagement());
    try sequence.onManageStart();
    try sequence.requireManagement();
    try sequence.requireRendering();
    try sequence.completeManage();
    try std.testing.expectError(error.InvalidRequestPhase, sequence.requireRendering());
    try sequence.onRenderStart();
    try std.testing.expectError(error.InvalidRequestPhase, sequence.requireManagement());
    try sequence.requireRendering();
}
