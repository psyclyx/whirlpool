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

    pub fn init(allocator: std.mem.Allocator, limit: usize) Queue {
        return .{ .allocator = allocator, .limit = limit };
    }

    pub fn deinit(
        self: *Queue,
        context: ?*anyopaque,
        discard: ?*const fn (?*anyopaque, coordinator.SubmittedCommit) void,
    ) void {
        if (discard) |callback| for (self.entries.items) |entry|
            callback(context, entry.value);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn enqueue(self: *Queue, commit: coordinator.SubmittedCommit) !void {
        if (commit.generation == 0 or commit.token == 0) return error.InvalidSubmittedCommit;
        if (self.entries.items.len >= self.limit) return error.SurfaceCommitLimitExceeded;
        for (self.entries.items) |entry| {
            if (!entry.cancelled and sameRole(entry.value.role, commit.role))
                return error.SurfaceCommitAlreadyPending;
        }
        try self.entries.append(self.allocator, .{ .value = commit });
    }

    pub fn count(self: *const Queue) usize {
        return self.entries.items.len;
    }

    pub fn appendReady(self: *const Queue, allocator: std.mem.Allocator, output: *std.ArrayList(coordinator.SubmittedCommit)) !void {
        for (self.entries.items) |entry| if (!entry.cancelled)
            try output.append(allocator, entry.value);
    }

    pub fn cancel(self: *Queue, role: coordinator.SurfaceRole) void {
        for (self.entries.items) |*entry| {
            if (!entry.cancelled and sameRole(entry.value.role, role)) entry.cancelled = true;
        }
    }

    pub fn discardCancelled(
        self: *Queue,
        context: ?*anyopaque,
        discard: *const fn (?*anyopaque, coordinator.SubmittedCommit) void,
    ) usize {
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
        return discarded;
    }

    pub fn complete(self: *Queue, commit: coordinator.SubmittedCommit) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (!entry.cancelled and entry.value.generation == commit.generation and
                entry.value.token == commit.token and sameRole(entry.value.role, commit.role))
            {
                _ = self.entries.orderedRemove(index);
                return true;
            }
        }
        return false;
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
