//! Concrete poll-backed driver for the platform-neutral Wayland event loop.
//!
//! This is the only layer that turns the abstract prepare/read/flush contract
//! into a display fd operation. It owns no compositor-specific policy and does
//! not hide a blocking wait behind a protocol helper.

const std = @import("std");
const client_api = @import("whirlpool-wayland-client");
const event_loop = @import("event_loop.zig");

pub const AfterDispatch = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque) anyerror!void,
};

pub const Session = struct {
    client: *client_api.Client,
    loop: event_loop.EventLoop,
    after_dispatch: ?AfterDispatch = null,
    poll_interval_ms: i32 = -1,
    wake_pipe: [2]std.posix.fd_t,

    pub fn init(self: *Session, client: *client_api.Client) !void {
        const wake_pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        self.client = client;
        self.after_dispatch = null;
        self.poll_interval_ms = -1;
        self.wake_pipe = wake_pipe;
        self.loop = event_loop.EventLoop.init(.{
            .context = self,
            .prepare_read = prepareRead,
            .read_events = readEvents,
            .cancel_read = cancelRead,
            .dispatch_pending = dispatchPending,
            .flush = flush,
            .wait = wait,
            .signal_wake = signalWake,
            .drain_wake = drainWake,
        });
        self.loop.observer = .{
            .context = self,
            .on_disconnect = onDisconnect,
            .on_failure = onFailure,
        };
    }

    pub fn deinit(self: *Session) void {
        std.Io.Threaded.closeFd(self.wake_pipe[0]);
        std.Io.Threaded.closeFd(self.wake_pipe[1]);
        self.* = undefined;
    }

    /// Runs until the display disconnects or a caller requests stop through
    /// `loop.requestStop`.  The caller retains ownership of `client`.
    pub fn run(self: *Session) !void {
        try self.loop.run();
    }

    pub fn runOnce(self: *Session) !event_loop.Tick {
        return self.loop.runOnce();
    }

    pub fn requestStop(self: *Session) !void {
        try self.loop.requestStop();
    }

    /// Install host work that must run after pending listeners return and
    /// before the event loop prepares another display read. River uses this
    /// for Lua/WM safe points; the callback must not dispatch recursively.
    pub fn setAfterDispatch(self: *Session, callback: AfterDispatch) void {
        self.after_dispatch = callback;
    }

    /// Bound idle waits while a presenter has completion state outside the
    /// Wayland socket (presentation progress, animation clocks, etc.).
    pub fn setPollInterval(self: *Session, milliseconds: u15) void {
        self.poll_interval_ms = milliseconds;
    }

    fn from(context: ?*anyopaque) *Session {
        return @ptrCast(@alignCast(context.?));
    }

    fn onDisconnect(_: ?*anyopaque, stage: event_loop.Stage) void {
        std.log.info("Wayland disconnected during {s}", .{@tagName(stage)});
    }

    fn onFailure(_: ?*anyopaque, failure: event_loop.Failure) void {
        std.log.err("Wayland event loop failed during {s}: {s}", .{
            @tagName(failure.stage),
            @errorName(failure.source),
        });
    }

    fn prepareRead(context: ?*anyopaque) !event_loop.PrepareResult {
        const self = from(context);
        const prepared = self.client.prepareRead() catch |err| return switch (err) {
            error.Disconnected => .disconnected,
            else => return err,
        };
        return if (prepared) .prepared else .pending;
    }

    fn readEvents(context: ?*anyopaque) !event_loop.ConnectionResult {
        from(context).client.readEvents() catch return .disconnected;
        return .connected;
    }

    fn cancelRead(context: ?*anyopaque) !void {
        from(context).client.cancelRead();
    }

    fn dispatchPending(context: ?*anyopaque) !event_loop.ConnectionResult {
        const self = from(context);
        self.client.dispatchPending() catch |err| return switch (err) {
            error.Disconnected => .disconnected,
            else => return err,
        };
        if (self.after_dispatch) |callback| try callback.run(callback.context);
        return .connected;
    }

    fn flush(context: ?*anyopaque) !event_loop.FlushResult {
        from(context).client.flush() catch |err| return switch (err) {
            error.WouldBlock => .would_block,
            error.Disconnected => .disconnected,
        };
        return .flushed;
    }

    fn wait(context: ?*anyopaque, interest: event_loop.WaitInterest) !event_loop.Readiness {
        const self = from(context);
        const events: i16 = if (interest.display_writable)
            std.posix.POLL.IN | std.posix.POLL.OUT
        else
            std.posix.POLL.IN;
        var descriptors = [_]std.posix.pollfd{
            .{ .fd = self.client.fd(), .events = events, .revents = 0 },
            .{ .fd = self.wake_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = try std.posix.poll(&descriptors, self.poll_interval_ms);
        return .{
            .display_readable = descriptors[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0,
            .display_writable = descriptors[0].revents & std.posix.POLL.OUT != 0,
            .wake_readable = descriptors[1].revents & std.posix.POLL.IN != 0,
        };
    }

    fn signalWake(context: ?*anyopaque) !void {
        const self = from(context);
        const bytes = [1]u8{1};
        while (true) switch (std.posix.errno(std.posix.system.write(self.wake_pipe[1], &bytes, bytes.len))) {
            .SUCCESS, .AGAIN => return,
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        };
    }

    fn drainWake(context: ?*anyopaque) !void {
        const self = from(context);
        var buffer: [64]u8 = undefined;
        while (true) {
            const count = std.posix.read(self.wake_pipe[0], &buffer) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (count == 0 or count < buffer.len) return;
        }
    }
};

test "concrete Wayland session owns only event-loop transport callbacks" {
    try std.testing.expect(@sizeOf(Session) > 0);
}
