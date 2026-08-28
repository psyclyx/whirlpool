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

    /// Record that River has emitted at least one manager event.
    pub fn noteServerEvent(self: *Sequence) !void {
        self.assertValid();
        try self.requireActive();
        self.server_event_seen = true;
        self.assertValid();
    }

    /// Enter a manage sequence from idle.
    pub fn onManageStart(self: *Sequence) !void {
        self.assertValid();
        try self.requireActive();
        if (self.phase != .idle) return error.InvalidSequence;
        self.server_event_seen = true;
        self.manage_dirty_requested = false;
        self.phase = .managing;
        self.assertValid();
    }

    /// Enter a render sequence from an eligible phase.
    pub fn onRenderStart(self: *Sequence) !void {
        self.assertValid();
        try self.requireActive();
        if (self.phase != .idle and self.phase != .awaiting_render) {
            return error.InvalidSequence;
        }
        self.server_event_seen = true;
        self.phase = .rendering;
        self.assertValid();
    }

    /// Complete the active manage sequence.
    pub fn completeManage(self: *Sequence) !void {
        self.assertValid();
        try self.requireActive();
        if (self.phase != .managing) return error.InvalidSequence;
        self.phase = .awaiting_render;
        self.assertValid();
    }

    /// Complete the active render sequence.
    pub fn completeRender(self: *Sequence) !void {
        self.assertValid();
        try self.requireActive();
        if (self.phase != .rendering) return error.InvalidSequence;
        self.phase = .idle;
        self.assertValid();
    }

    /// Request another manage cycle while the manager is active.
    pub fn requestManageDirty(self: *Sequence) !void {
        try self.requireActive();
        if (self.stop_requested) return error.Stopping;
        self.manage_dirty_requested = true;
    }

    /// Request orderly manager shutdown exactly once.
    pub fn requestStop(self: *Sequence) !void {
        try self.requireActive();
        if (self.stop_requested) return error.Stopping;
        self.stop_requested = true;
    }

    /// Mark a manager that was unavailable before any other event.
    pub fn onUnavailable(self: *Sequence) !void {
        try self.requireActive();
        if (self.server_event_seen or self.phase != .idle or self.stop_requested) {
            return error.InvalidSequence;
        }
        self.server_event_seen = true;
        self.terminal = .unavailable;
        self.assertValid();
    }

    /// Mark orderly completion after shutdown and active work finish.
    pub fn onFinished(self: *Sequence) !void {
        try self.requireActive();
        if (!self.stop_requested or self.phase == .managing or self.phase == .rendering) {
            return error.InvalidSequence;
        }
        self.server_event_seen = true;
        self.terminal = .finished;
        self.assertValid();
    }

    /// Mark a terminal manager as destroyed.
    pub fn destroy(self: *Sequence) !void {
        self.assertValid();
        if (self.terminal != .unavailable and self.terminal != .finished) {
            return error.DestroyBeforeFinished;
        }
        self.terminal = .destroyed;
        self.assertValid();
    }

    /// Require the request phase reserved for manage operations.
    pub fn requireManagement(self: *const Sequence) !void {
        self.assertValid();
        try self.requireActive();
        if (self.phase != .managing) return error.InvalidRequestPhase;
    }

    /// Require a phase where render-class requests are legal.
    pub fn requireRendering(self: *const Sequence) !void {
        self.assertValid();
        try self.requireActive();
        if (self.phase != .managing and self.phase != .rendering) {
            return error.InvalidRequestPhase;
        }
    }

    fn requireActive(self: *const Sequence) !void {
        if (self.terminal != .active) return error.ProtocolClosed;
    }

    fn assertValid(self: *const Sequence) void {
        switch (self.terminal) {
            .active => {},
            .unavailable => {
                std.debug.assert(self.phase == .idle);
                std.debug.assert(!self.stop_requested);
            },
            .finished, .destroyed => {
                std.debug.assert(self.stop_requested);
                std.debug.assert(self.phase != .managing and self.phase != .rendering);
            },
        }
        if (self.phase != .idle) std.debug.assert(self.server_event_seen);
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
