//! Bounded ownership queue for prepared surface submissions.

const std = @import("std");
const host = @import("whirlpool-host");

const coordinator = host.river_coordinator;

const Entry = struct {
    value: coordinator.SubmittedCommit,
    cancelled: bool = false,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    entries: std.ArrayList(Entry) = .empty,

    /// Initialize an empty queue with a fixed pending-commit limit.
    pub fn init(allocator: std.mem.Allocator, limit: usize) Queue {
        std.debug.assert(limit > 0);
        return .{ .allocator = allocator, .limit = limit };
    }

    /// Discard every queued commit and release queue storage.
    pub fn deinit(
        self: *Queue,
        context: ?*anyopaque,
        discard: ?*const fn (?*anyopaque, coordinator.SubmittedCommit) void,
    ) void {
        self.assertValid();
        if (discard) |callback| for (self.entries.items) |entry|
            callback(context, entry.value);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Take ownership of one valid commit for a role without a pending entry.
    pub fn enqueue(self: *Queue, commit: coordinator.SubmittedCommit) !void {
        self.assertValid();
        if (commit.generation == 0 or commit.token == 0) return error.InvalidSubmittedCommit;
        if (self.entries.items.len >= self.limit) return error.SurfaceCommitLimitExceeded;
        for (self.entries.items) |entry| {
            if (!entry.cancelled and sameRole(entry.value.role, commit.role))
                return error.SurfaceCommitAlreadyPending;
        }
        try self.entries.append(self.allocator, .{ .value = commit });
        self.assertValid();
        std.debug.assert(self.entries.items.len <= self.limit);
    }

    /// Return the number of queued entries, including cancelled entries.
    pub fn count(self: *const Queue) usize {
        self.assertValid();
        return self.entries.items.len;
    }

    /// Append every non-cancelled commit to output without transferring ownership.
    pub fn appendReady(self: *const Queue, allocator: std.mem.Allocator, output: *std.ArrayList(coordinator.SubmittedCommit)) !void {
        self.assertValid();
        const previous_len = output.items.len;
        for (self.entries.items) |entry| if (!entry.cancelled)
            try output.append(allocator, entry.value);
        std.debug.assert(output.items.len >= previous_len);
    }

    /// Mark the pending commit for role as cancelled.
    pub fn cancel(self: *Queue, role: coordinator.SurfaceRole) void {
        self.assertValid();
        for (self.entries.items) |*entry| {
            if (!entry.cancelled and sameRole(entry.value.role, role)) entry.cancelled = true;
        }
        self.assertValid();
    }

    /// Discard cancelled entries and return how many were removed.
    pub fn discardCancelled(
        self: *Queue,
        context: ?*anyopaque,
        discard: *const fn (?*anyopaque, coordinator.SubmittedCommit) void,
    ) usize {
        self.assertValid();
        const previous_len = self.entries.items.len;
        var discarded: usize = 0;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (!self.entries.items[index].cancelled) {
                index += 1;
                continue;
            }
            const entry = self.entries.orderedRemove(index);
            discard(context, entry.value);
            discarded += 1;
        }
        self.assertValid();
        std.debug.assert(self.entries.items.len + discarded == previous_len);
        return discarded;
    }

    /// Complete and remove an exact live commit.
    pub fn complete(self: *Queue, commit: coordinator.SubmittedCommit) bool {
        self.assertValid();
        for (self.entries.items, 0..) |entry, index| {
            if (!entry.cancelled and entry.value.generation == commit.generation and
                entry.value.token == commit.token and sameRole(entry.value.role, commit.role))
            {
                _ = self.entries.orderedRemove(index);
                self.assertValid();
                return true;
            }
        }
        return false;
    }

    fn assertValid(self: *const Queue) void {
        std.debug.assert(self.limit > 0);
        std.debug.assert(self.entries.items.len <= self.limit);
        for (self.entries.items, 0..) |entry, index| {
            std.debug.assert(entry.value.generation != 0);
            std.debug.assert(entry.value.token != 0);
            if (entry.cancelled) continue;
            for (self.entries.items[index + 1 ..]) |other| {
                std.debug.assert(other.cancelled or !sameRole(entry.value.role, other.value.role));
            }
        }
    }
};

fn sameRole(a: coordinator.SurfaceRole, b: coordinator.SurfaceRole) bool {
    return switch (a) {
        .shell => |id| switch (b) {
            .shell => |other| id.value == other.value,
            else => false,
        },
        .decoration => |id| switch (b) {
            .decoration => |other| id.value == other.value,
            else => false,
        },
    };
}

test "queue owns duplicate cancellation and completion rules" {
    var queue = Queue.init(std.testing.allocator, 2);
    defer queue.deinit(null, null);
    const first = coordinator.SubmittedCommit{
        .role = .{ .shell = host.types.ShellSurfaceId.init(1) },
        .generation = 2,
        .token = 3,
    };
    try queue.enqueue(first);
    try std.testing.expectError(error.SurfaceCommitAlreadyPending, queue.enqueue(.{
        .role = first.role,
        .generation = 4,
        .token = 5,
    }));
    try std.testing.expect(queue.complete(first));
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}
