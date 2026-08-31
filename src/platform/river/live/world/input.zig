//! Typed input crossing the River protocol boundary.
//!
//! Generated callbacks may only append these values.  The host consumes them
//! at its existing post-dispatch safe point and resolves the named action
//! through policy there.

const std = @import("std");
const host = @import("whirlpool-host");
const ids = host.types;

pub const NamedAction = enum {
    focus,
    move,
    resize,
    close,
    toggle_floating,
    toggle_fullscreen,
    next_column,
    previous_column,
};

pub const Source = union(enum) {
    pointer_binding: ids.PointerBindingId,
    decoration: ids.DecorationId,
    window_request: ids.WindowId,
};

pub const Intent = struct {
    action: NamedAction,
    source: Source,
    seat: ?ids.SeatId = null,
    window: ?ids.WindowId = null,
    position: ?ids.Point = null,
    delta: ids.Point = .{ .x = 0, .y = 0 },
    edges: ?u32 = null,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    items: std.ArrayList(Intent) = .empty,

    pub fn init(allocator: std.mem.Allocator, limit: usize) Queue {
        return .{ .allocator = allocator, .limit = limit };
    }

    pub fn deinit(self: *Queue) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Queue, intent: Intent) !void {
        if (self.items.items.len >= self.limit) return error.InputIntentLimitExceeded;
        try self.items.append(self.allocator, intent);
    }

    pub fn take(self: *Queue) ![]Intent {
        return self.items.toOwnedSlice(self.allocator);
    }

    pub fn count(self: *const Queue) usize {
        return self.items.items.len;
    }
};

test "input intents are bounded and transferred atomically" {
    var queue = Queue.init(std.testing.allocator, 1);
    defer queue.deinit();
    try queue.append(.{ .action = .focus, .source = .{ .pointer_binding = .init(1) } });
    try std.testing.expectError(error.InputIntentLimitExceeded, queue.append(.{ .action = .close, .source = .{ .pointer_binding = .init(2) } }));
    const intents = try queue.take();
    defer std.testing.allocator.free(intents);
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}
