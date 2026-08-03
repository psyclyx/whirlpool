//! State machine for river-window-management-v1's atomic sequences.

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

    /// Call for state-bearing server events received before manage_start.
    pub fn noteServerEvent(self: *Sequence) !void {
        try self.requireActive();
        self.server_event_seen = true;
    }

    pub fn onManageStart(self: *Sequence) !void {
        try self.requireActive();
        if (self.phase != .idle) return error.InvalidSequence;
        self.server_event_seen = true;
        self.phase = .managing;
    }

    pub fn finishManage(self: *Sequence) !void {
        try self.requireActive();
        if (self.phase != .managing) return error.InvalidSequence;
        self.phase = .awaiting_render;
    }

    pub fn onRenderStart(self: *Sequence) !void {
        try self.requireActive();
        if (self.phase != .idle and self.phase != .awaiting_render) {
            return error.InvalidSequence;
        }
        self.server_event_seen = true;
        self.phase = .rendering;
    }

    pub fn finishRender(self: *Sequence) !void {
        try self.requireActive();
        if (self.phase != .rendering) return error.InvalidSequence;
        self.phase = .idle;
    }

    pub fn requestManageDirty(self: *Sequence) !void {
        try self.requireActive();
        if (self.stop_requested) return error.Stopping;
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
        self.server_event_seen = true;
        self.terminal = .finished;
    }

    pub fn destroy(self: *Sequence) !void {
        if (self.terminal != .unavailable and self.terminal != .finished) {
            return error.DestroyBeforeFinished;
        }
        self.terminal = .destroyed;
    }

    pub fn mayChangeManagement(self: *const Sequence) bool {
        return self.terminal == .active and self.phase == .managing;
    }

    pub fn mayChangeRendering(self: *const Sequence) bool {
        return self.terminal == .active and
            (self.phase == .managing or self.phase == .rendering);
    }

    fn requireActive(self: *const Sequence) !void {
        if (self.terminal != .active) return error.ProtocolClosed;
    }
};

test "canonical manage then render transaction exposes the right capabilities" {
    var sequence: Sequence = .{};
    try sequence.noteServerEvent();
    try sequence.onManageStart();
    try std.testing.expect(sequence.mayChangeManagement());
    try std.testing.expect(sequence.mayChangeRendering());

    try sequence.finishManage();
    try std.testing.expectEqual(Phase.awaiting_render, sequence.phase);
    try std.testing.expect(!sequence.mayChangeManagement());
    try std.testing.expect(!sequence.mayChangeRendering());

    try sequence.onRenderStart();
    try std.testing.expect(!sequence.mayChangeManagement());
    try std.testing.expect(sequence.mayChangeRendering());
    try sequence.finishRender();
    try std.testing.expectEqual(Phase.idle, sequence.phase);
}

test "consecutive render transactions are valid but crossed finishes are not" {
    var sequence: Sequence = .{};
    try std.testing.expectError(error.InvalidSequence, sequence.finishManage());
    try std.testing.expectError(error.InvalidSequence, sequence.finishRender());
    try std.testing.expectEqual(Phase.idle, sequence.phase);

    try sequence.onRenderStart();
    try std.testing.expectError(error.InvalidSequence, sequence.onManageStart());
    try std.testing.expectError(error.InvalidSequence, sequence.finishManage());
    try std.testing.expectEqual(Phase.rendering, sequence.phase);
    try sequence.finishRender();
    try sequence.onRenderStart();
    try sequence.finishRender();
}

test "stop permits in-flight asynchronous events until finished" {
    var sequence: Sequence = .{};
    try sequence.requestStop();
    try std.testing.expectError(error.Stopping, sequence.requestStop());
    try std.testing.expectError(error.Stopping, sequence.requestManageDirty());

    try sequence.onManageStart();
    try sequence.finishManage();
    try sequence.onRenderStart();
    try sequence.finishRender();
    try sequence.onFinished();
    try std.testing.expectEqual(Terminal.finished, sequence.terminal);
    try std.testing.expectError(error.ProtocolClosed, sequence.onManageStart());
    try sequence.destroy();
    try std.testing.expectEqual(Terminal.destroyed, sequence.terminal);
}

test "unavailable is accepted only as the first server event" {
    var unavailable: Sequence = .{};
    try unavailable.onUnavailable();
    try std.testing.expectError(error.ProtocolClosed, unavailable.requestStop());
    try unavailable.destroy();

    var late: Sequence = .{};
    try late.noteServerEvent();
    try std.testing.expectError(error.InvalidSequence, late.onUnavailable());
    try std.testing.expectEqual(Terminal.active, late.terminal);
    try std.testing.expectError(error.DestroyBeforeFinished, late.destroy());
}
