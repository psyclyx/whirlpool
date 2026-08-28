//! Platform-neutral Wayland display event-loop boundary.
//!
//! A concrete adapter maps these callbacks to `wl_display_prepare_read`,
//! `wl_display_read_events`, `wl_display_cancel_read`, pending dispatch,
//! socket polling, and flushing. This module never opens or touches a socket.
//! River transports can delegate `dispatch_pending` and `flush` to
//! `river.Host.dispatchPending` and `river.Host.flushOutgoing` respectively.

const std = @import("std");

pub const Stage = enum {
    prepare_read,
    read_events,
    cancel_read,
    dispatch_pending,
    flush,
    wait,
    signal_wake,
    drain_wake,
};

pub const Failure = struct {
    stage: Stage,
    source: anyerror,
};

pub const PrepareResult = enum { prepared, pending, disconnected };
pub const ConnectionResult = enum { connected, disconnected };
pub const FlushResult = enum { flushed, would_block, disconnected };

pub const Readiness = packed struct {
    display_readable: bool = false,
    display_writable: bool = false,
    wake_readable: bool = false,
};

pub const WaitInterest = packed struct {
    display_writable: bool = false,
};

pub const Callbacks = struct {
    context: ?*anyopaque = null,
    prepare_read: *const fn (?*anyopaque) anyerror!PrepareResult,
    read_events: *const fn (?*anyopaque) anyerror!ConnectionResult,
    cancel_read: *const fn (?*anyopaque) anyerror!void,
    dispatch_pending: *const fn (?*anyopaque) anyerror!ConnectionResult,
    flush: *const fn (?*anyopaque) anyerror!FlushResult,
    wait: *const fn (?*anyopaque, WaitInterest) anyerror!Readiness,
    signal_wake: *const fn (?*anyopaque) anyerror!void,
    drain_wake: *const fn (?*anyopaque) anyerror!void,
};

pub const Observer = struct {
    context: ?*anyopaque = null,
    on_disconnect: *const fn (?*anyopaque, Stage) void = ignoreDisconnect,
    on_failure: *const fn (?*anyopaque, Failure) void = ignoreFailure,

    fn ignoreDisconnect(_: ?*anyopaque, _: Stage) void {}
    fn ignoreFailure(_: ?*anyopaque, _: Failure) void {}
};

pub const State = enum(u8) { ready, running, stopping, stopped, disconnected, failed };
pub const Tick = enum { dispatched, idle, woken, stopped };
pub const Error = error{ InvalidState, BackendFailure, Disconnected };

/// `EventLoop` is driven by one loop thread. `wake` and `requestStop` may be
/// called by producers on other threads; their state is atomic and the
/// adapter-provided wake signal interrupts its wait primitive.
pub const EventLoop = struct {
    callbacks: Callbacks,
    observer: Observer = .{},
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.ready),
    read_prepared: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    consumed_wake_generation: u64 = 0,
    ticks: u64 = 0,
    dispatches: u64 = 0,

    pub fn init(callbacks: Callbacks) EventLoop {
        return .{ .callbacks = callbacks };
    }

    pub fn wake(self: *EventLoop) Error!void {
        if (self.isTerminal()) return error.InvalidState;
        _ = self.wake_generation.fetchAdd(1, .release);
        self.callbacks.signal_wake(self.callbacks.context) catch |source| {
            return self.fail(.signal_wake, source);
        };
    }

    pub fn requestStop(self: *EventLoop) Error!void {
        if (self.isTerminal()) return error.InvalidState;
        self.stop_requested.store(true, .release);
        try self.wake();
    }

    pub fn run(self: *EventLoop) Error!void {
        while (true) {
            if (try self.runOnce() == .stopped) return;
        }
    }

    /// Performs one prepare/flush/wait/read-or-cancel/dispatch cycle.
    pub fn runOnce(self: *EventLoop) Error!Tick {
        if (self.isTerminal()) return error.InvalidState;
        if (self.state.load(.acquire) == .ready) self.state.store(.running, .release);
        if (self.stop_requested.load(.acquire)) self.state.store(.stopping, .release);
        self.ticks += 1;

        while (true) {
            const prepared = self.callbacks.prepare_read(self.callbacks.context) catch |source| {
                return self.fail(.prepare_read, source);
            };
            switch (prepared) {
                .prepared => {
                    self.read_prepared = true;
                    break;
                },
                .pending => try self.dispatch(.dispatch_pending),
                .disconnected => return self.disconnect(.prepare_read),
            }
        }

        const flushed = self.callbacks.flush(self.callbacks.context) catch |source| {
            try self.cancelPrepared();
            return self.fail(.flush, source);
        };
        if (flushed == .disconnected) {
            try self.cancelPrepared();
            return self.disconnect(.flush);
        }

        const readiness = self.callbacks.wait(self.callbacks.context, .{
            .display_writable = flushed == .would_block,
        }) catch |source| {
            try self.cancelPrepared();
            return self.fail(.wait, source);
        };

        if (readiness.display_readable) {
            self.read_prepared = false;
            const result = self.callbacks.read_events(self.callbacks.context) catch |source| {
                return self.fail(.read_events, source);
            };
            if (result == .disconnected) return self.disconnect(.read_events);
        } else {
            try self.cancelPrepared();
        }

        var woke = false;
        if (readiness.wake_readable) {
            self.callbacks.drain_wake(self.callbacks.context) catch |source| {
                return self.fail(.drain_wake, source);
            };
            self.consumed_wake_generation = self.wake_generation.load(.acquire);
            woke = true;
        }

        try self.dispatch(.dispatch_pending);

        if (self.stop_requested.load(.acquire)) {
            self.state.store(.stopped, .release);
            return .stopped;
        }
        if (woke or self.hasPendingWake()) return .woken;
        if (readiness.display_readable) return .dispatched;
        return .idle;
    }

    pub fn hasPendingWake(self: *const EventLoop) bool {
        return self.wake_generation.load(.acquire) != self.consumed_wake_generation;
    }

    pub fn currentState(self: *const EventLoop) State {
        return self.state.load(.acquire);
    }

    fn dispatch(self: *EventLoop, stage: Stage) Error!void {
        const result = self.callbacks.dispatch_pending(self.callbacks.context) catch |source| {
            return self.fail(stage, source);
        };
        if (result == .disconnected) return self.disconnect(stage);
        self.dispatches += 1;
    }

    fn cancelPrepared(self: *EventLoop) Error!void {
        if (!self.read_prepared) return;
        self.read_prepared = false;
        self.callbacks.cancel_read(self.callbacks.context) catch |source| {
            return self.fail(.cancel_read, source);
        };
    }

    fn disconnect(self: *EventLoop, stage: Stage) Error {
        self.read_prepared = false;
        self.state.store(.disconnected, .release);
        self.observer.on_disconnect(self.observer.context, stage);
        return error.Disconnected;
    }

    fn fail(self: *EventLoop, stage: Stage, source: anyerror) Error {
        self.state.store(.failed, .release);
        self.observer.on_failure(self.observer.context, .{ .stage = stage, .source = source });
        return error.BackendFailure;
    }

    fn isTerminal(self: *const EventLoop) bool {
        return switch (self.state.load(.acquire)) {
            .stopped, .disconnected, .failed => true,
            else => false,
        };
    }
};

const Mock = struct {
    events: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    prepare_results: []const PrepareResult = &.{.prepared},
    prepare_index: usize = 0,
    readiness: Readiness = .{ .display_readable = true },
    flush_result: FlushResult = .flushed,
    read_result: ConnectionResult = .connected,
    dispatch_result: ConnectionResult = .connected,
    fail_stage: ?Stage = null,
    disconnected_at: ?Stage = null,
    failed_at: ?Stage = null,
    last_wait_interest: WaitInterest = .{},

    fn deinit(self: *Mock) void {
        self.events.deinit(self.allocator);
    }

    fn add(self: *Mock, event: u8) !void {
        try self.events.append(self.allocator, event);
    }

    fn from(context: ?*anyopaque) *Mock {
        return @ptrCast(@alignCast(context.?));
    }

    fn maybeFail(self: *Mock, stage: Stage) !void {
        if (self.fail_stage == stage) return error.MockFailure;
    }

    fn prepare(context: ?*anyopaque) !PrepareResult {
        const self = from(context);
        try self.add('p');
        try self.maybeFail(.prepare_read);
        const index = @min(self.prepare_index, self.prepare_results.len - 1);
        self.prepare_index += 1;
        return self.prepare_results[index];
    }

    fn read(context: ?*anyopaque) !ConnectionResult {
        const self = from(context);
        try self.add('r');
        try self.maybeFail(.read_events);
        return self.read_result;
    }

    fn cancel(context: ?*anyopaque) !void {
        const self = from(context);
        try self.add('c');
        try self.maybeFail(.cancel_read);
    }

    fn dispatch(context: ?*anyopaque) !ConnectionResult {
        const self = from(context);
        try self.add('d');
        try self.maybeFail(.dispatch_pending);
        return self.dispatch_result;
    }

    fn flush(context: ?*anyopaque) !FlushResult {
        const self = from(context);
        try self.add('f');
        try self.maybeFail(.flush);
        return self.flush_result;
    }

    fn wait(context: ?*anyopaque, interest: WaitInterest) !Readiness {
        const self = from(context);
        try self.add('w');
        try self.maybeFail(.wait);
        self.last_wait_interest = interest;
        return self.readiness;
    }

    fn signal(context: ?*anyopaque) !void {
        const self = from(context);
        try self.add('s');
        try self.maybeFail(.signal_wake);
    }

    fn drain(context: ?*anyopaque) !void {
        const self = from(context);
        try self.add('a');
        try self.maybeFail(.drain_wake);
    }

    fn onDisconnect(context: ?*anyopaque, stage: Stage) void {
        const self = from(context);
        self.disconnected_at = stage;
        self.add('x') catch unreachable;
    }

    fn onFailure(context: ?*anyopaque, failure: Failure) void {
        const self = from(context);
        self.failed_at = failure.stage;
        self.add('e') catch unreachable;
    }

    fn loop(self: *Mock) EventLoop {
        var result = EventLoop.init(.{
            .context = self,
            .prepare_read = prepare,
            .read_events = read,
            .cancel_read = cancel,
            .dispatch_pending = dispatch,
            .flush = flush,
            .wait = wait,
            .signal_wake = signal,
            .drain_wake = drain,
        });
        result.observer = .{
            .context = self,
            .on_disconnect = onDisconnect,
            .on_failure = onFailure,
        };
        return result;
    }
};

test "readable cycle prepares flushes reads then dispatches" {
    var mock = Mock{ .allocator = std.testing.allocator };
    defer mock.deinit();
    var loop = mock.loop();

    try std.testing.expectEqual(Tick.dispatched, try loop.runOnce());
    try std.testing.expectEqualSlices(u8, "pfwrd", mock.events.items);
    try std.testing.expect(!loop.read_prepared);
}

test "pending events dispatch before prepare retries" {
    const preparations = [_]PrepareResult{ .pending, .pending, .prepared };
    var mock = Mock{
        .allocator = std.testing.allocator,
        .prepare_results = &preparations,
        .readiness = .{},
    };
    defer mock.deinit();
    var loop = mock.loop();

    try std.testing.expectEqual(Tick.idle, try loop.runOnce());
    try std.testing.expectEqualSlices(u8, "pdpdpfwcd", mock.events.items);
    try std.testing.expectEqual(@as(u64, 3), loop.dispatches);
}

test "stop wakes wait cancels read drains wake and dispatches" {
    var mock = Mock{
        .allocator = std.testing.allocator,
        .readiness = .{ .wake_readable = true },
    };
    defer mock.deinit();
    var loop = mock.loop();

    try loop.requestStop();
    try std.testing.expectEqual(Tick.stopped, try loop.runOnce());
    try std.testing.expectEqual(State.stopped, loop.currentState());
    try std.testing.expectEqualSlices(u8, "spfwcad", mock.events.items);
    try std.testing.expect(!loop.hasPendingWake());
}

test "flush failure cancels prepared read before reporting error" {
    var mock = Mock{ .allocator = std.testing.allocator, .fail_stage = .flush };
    defer mock.deinit();
    var loop = mock.loop();

    try std.testing.expectError(error.BackendFailure, loop.runOnce());
    try std.testing.expectEqualSlices(u8, "pfce", mock.events.items);
    try std.testing.expectEqual(Stage.flush, mock.failed_at.?);
    try std.testing.expectEqual(State.failed, loop.currentState());
}

test "wait failure cancels prepared read before reporting error" {
    var mock = Mock{ .allocator = std.testing.allocator, .fail_stage = .wait };
    defer mock.deinit();
    var loop = mock.loop();

    try std.testing.expectError(error.BackendFailure, loop.runOnce());
    try std.testing.expectEqualSlices(u8, "pfwce", mock.events.items);
    try std.testing.expectEqual(Stage.wait, mock.failed_at.?);
}

test "read disconnect is terminal and observed without dispatch" {
    var mock = Mock{ .allocator = std.testing.allocator, .read_result = .disconnected };
    defer mock.deinit();
    var loop = mock.loop();

    try std.testing.expectError(error.Disconnected, loop.runOnce());
    try std.testing.expectEqualSlices(u8, "pfwrx", mock.events.items);
    try std.testing.expectEqual(Stage.read_events, mock.disconnected_at.?);
    try std.testing.expectEqual(State.disconnected, loop.currentState());
    try std.testing.expectError(error.InvalidState, loop.runOnce());
}

test "would-block flush is not a loop failure" {
    var mock = Mock{
        .allocator = std.testing.allocator,
        .flush_result = .would_block,
        .readiness = .{ .display_readable = true, .display_writable = true },
    };
    defer mock.deinit();
    var loop = mock.loop();

    try std.testing.expectEqual(Tick.dispatched, try loop.runOnce());
    try std.testing.expectEqualSlices(u8, "pfwrd", mock.events.items);
    try std.testing.expect(mock.last_wait_interest.display_writable);
}
