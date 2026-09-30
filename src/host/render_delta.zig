//! Send River only the rendering state that changed.
//!
//! River keeps every window's rendering state (position, visibility, borders,
//! clips) until it is changed, and applies it at `render_finish`. A layout plan
//! restates all of it every time, so most of what would be sent is already
//! true. This filter remembers what was last sent and passes through only the
//! differences.
//!
//! To stay predictable it does not trust the cache blindly. Everything is
//! resent ("a full refresh") when
//!   * the topology changes: a window or output appeared, went away or moved;
//!   * a refresh interval of render sequences has elapsed; or
//!   * a previous render failed part-way, so what River holds is uncertain.
//! Stacking order is treated as one unit: it is resent whole whenever any of it
//! changes, never patched.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Operation = types.RenderOperation;

/// Render sequences between unconditional full refreshes.
pub const default_refresh_interval: u32 = 240;

const Kind = enum(u8) { visibility, borders, clip, content_clip, position, decoration_offset };
const Key = struct { kind: Kind, id: u64 };

pub const Result = struct {
    sent: usize = 0,
    skipped: usize = 0,
    full: bool = false,
};

pub const RenderDelta = struct {
    allocator: Allocator,
    refresh_interval: u32 = default_refresh_interval,
    last: std.AutoHashMapUnmanaged(Key, Operation) = .empty,
    /// The stacking operations of the last render, in order.
    order: std.ArrayList(Operation) = .empty,
    topology: ?u64 = null,
    since_full: u32 = 0,

    pub fn init(allocator: Allocator) RenderDelta {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RenderDelta) void {
        self.last.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.* = undefined;
    }

    /// Forget everything: the next `filter` sends it all.
    pub fn invalidate(self: *RenderDelta) void {
        self.last.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.topology = null;
    }

    /// Whether the next `filter` for this topology will be a full refresh.
    pub fn refreshDue(self: *const RenderDelta, topology: u64) bool {
        return self.topology != topology or self.since_full >= self.refresh_interval;
    }

    /// Append to `out` the operations of `plan` that River does not already
    /// have. `topology` summarises the set of windows and outputs.
    pub fn filter(
        self: *RenderDelta,
        plan: []const Operation,
        out: *std.ArrayList(Operation),
        topology: u64,
    ) Allocator.Error!Result {
        var result = Result{};
        if (self.refreshDue(topology)) {
            self.invalidate();
            self.topology = topology;
            self.since_full = 0;
            result.full = true;
        }
        self.since_full +|= 1;

        var placements: std.ArrayList(Operation) = .empty;
        defer placements.deinit(self.allocator);
        for (plan) |operation| {
            if (isPlacement(operation)) {
                try placements.append(self.allocator, operation);
                continue;
            }
            const key = keyOf(operation) orelse {
                // Not state (a sync request paired with a commit): always sent.
                try out.append(self.allocator, operation);
                result.sent += 1;
                continue;
            };
            const entry = try self.last.getOrPut(self.allocator, key);
            if (entry.found_existing and std.meta.eql(entry.value_ptr.*, operation)) {
                result.skipped += 1;
                continue;
            }
            entry.value_ptr.* = operation;
            try out.append(self.allocator, operation);
            result.sent += 1;
        }

        // Stacking is resent whole, and only if any of it changed.
        if (!sameOrder(self.order.items, placements.items)) {
            try out.appendSlice(self.allocator, placements.items);
            result.sent += placements.items.len;
            self.order.clearRetainingCapacity();
            try self.order.appendSlice(self.allocator, placements.items);
        } else {
            result.skipped += placements.items.len;
        }
        return result;
    }
};

fn isPlacement(operation: Operation) bool {
    return switch (operation) {
        .place_top, .place_bottom, .place_above, .place_below => true,
        else => false,
    };
}

fn sameOrder(left: []const Operation, right: []const Operation) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

/// The piece of state an operation sets, or null for operations that are
/// requests rather than state.
fn keyOf(operation: Operation) ?Key {
    return switch (operation) {
        .hide => |window| .{ .kind = .visibility, .id = window.value },
        .show => |window| .{ .kind = .visibility, .id = window.value },
        .set_borders => |value| .{ .kind = .borders, .id = value.window.value },
        .set_clip_box => |value| .{ .kind = .clip, .id = value.window.value },
        .set_content_clip_box => |value| .{ .kind = .content_clip, .id = value.window.value },
        .set_position => |value| .{ .kind = .position, .id = value.node.value },
        .decoration_set_offset => |value| .{ .kind = .decoration_offset, .id = value.decoration.value },
        .place_top, .place_bottom, .place_above, .place_below => null,
        .decoration_sync_next_commit, .shell_surface_sync_next_commit => null,
    };
}

fn windowId(id: u64) types.WindowId {
    return types.WindowId.init(id);
}

fn moved(id: u64, x: i32) Operation {
    return .{ .set_position = .{ .node = types.NodeId.init(id), .position = .{ .x = x, .y = 0 } } };
}

fn run(delta: *RenderDelta, plan: []const Operation, topology: u64) !struct { sent: []Operation, result: Result } {
    var out: std.ArrayList(Operation) = .empty;
    errdefer out.deinit(std.testing.allocator);
    const result = try delta.filter(plan, &out, topology);
    return .{ .sent = try out.toOwnedSlice(std.testing.allocator), .result = result };
}

test "the first render sends everything and an identical one sends nothing" {
    var delta = RenderDelta.init(std.testing.allocator);
    defer delta.deinit();
    const plan = [_]Operation{
        .{ .show = windowId(1) },
        moved(1, 10),
        .{ .place_top = types.NodeId.init(1) },
    };
    const first = try run(&delta, &plan, 7);
    defer std.testing.allocator.free(first.sent);
    try std.testing.expect(first.result.full);
    try std.testing.expectEqual(@as(usize, 3), first.sent.len);

    const second = try run(&delta, &plan, 7);
    defer std.testing.allocator.free(second.sent);
    try std.testing.expect(!second.result.full);
    try std.testing.expectEqual(@as(usize, 0), second.sent.len);
    try std.testing.expectEqual(@as(usize, 3), second.result.skipped);
}

test "only changed state is sent, per window and per kind" {
    var delta = RenderDelta.init(std.testing.allocator);
    defer delta.deinit();
    const before = [_]Operation{ .{ .show = windowId(1) }, moved(1, 10), .{ .show = windowId(2) }, moved(2, 50) };
    const warm = try run(&delta, &before, 1);
    defer std.testing.allocator.free(warm.sent);

    // Window 2 scrolls; window 1 hides. Position of 1 and visibility of 2 stand.
    const after = [_]Operation{ .{ .hide = windowId(1) }, moved(1, 10), .{ .show = windowId(2) }, moved(2, 60) };
    const next = try run(&delta, &after, 1);
    defer std.testing.allocator.free(next.sent);
    try std.testing.expectEqual(@as(usize, 2), next.sent.len);
    try std.testing.expect(std.meta.eql(next.sent[0], after[0]));
    try std.testing.expect(std.meta.eql(next.sent[1], after[3]));
}

test "stacking order is resent whole when any of it changes" {
    var delta = RenderDelta.init(std.testing.allocator);
    defer delta.deinit();
    const a = types.NodeId.init(1);
    const b = types.NodeId.init(2);
    const order_one = [_]Operation{ .{ .place_top = a }, .{ .place_top = b } };
    const warm = try run(&delta, &order_one, 1);
    defer std.testing.allocator.free(warm.sent);

    const same = try run(&delta, &order_one, 1);
    defer std.testing.allocator.free(same.sent);
    try std.testing.expectEqual(@as(usize, 0), same.sent.len);

    const swapped = [_]Operation{ .{ .place_top = b }, .{ .place_top = a } };
    const changed = try run(&delta, &swapped, 1);
    defer std.testing.allocator.free(changed.sent);
    try std.testing.expectEqual(@as(usize, 2), changed.sent.len);
}

test "sync requests are never filtered" {
    var delta = RenderDelta.init(std.testing.allocator);
    defer delta.deinit();
    const plan = [_]Operation{.{ .decoration_sync_next_commit = types.DecorationId.init(3) }};
    for (0..3) |_| {
        const step = try run(&delta, &plan, 1);
        defer std.testing.allocator.free(step.sent);
        try std.testing.expectEqual(@as(usize, 1), step.sent.len);
    }
}

test "a topology change forces a full refresh" {
    var delta = RenderDelta.init(std.testing.allocator);
    defer delta.deinit();
    const plan = [_]Operation{ .{ .show = windowId(1) }, moved(1, 10) };
    const warm = try run(&delta, &plan, 1);
    defer std.testing.allocator.free(warm.sent);
    const steady = try run(&delta, &plan, 1);
    defer std.testing.allocator.free(steady.sent);
    try std.testing.expectEqual(@as(usize, 0), steady.sent.len);

    // A window or output appeared: everything is stated again, unchanged or not.
    const changed = try run(&delta, &plan, 2);
    defer std.testing.allocator.free(changed.sent);
    try std.testing.expect(changed.result.full);
    try std.testing.expectEqual(@as(usize, 2), changed.sent.len);
}

test "a full refresh happens every interval, and after invalidation" {
    var delta = RenderDelta.init(std.testing.allocator);
    defer delta.deinit();
    delta.refresh_interval = 4;
    const plan = [_]Operation{ .{ .show = windowId(1) }, moved(1, 10) };
    var fulls: usize = 0;
    for (0..9) |_| {
        const step = try run(&delta, &plan, 1);
        defer std.testing.allocator.free(step.sent);
        if (step.result.full) fulls += 1;
    }
    // Renders 1, 5 and 9 of nine.
    try std.testing.expectEqual(@as(usize, 3), fulls);

    delta.invalidate();
    const after_failure = try run(&delta, &plan, 1);
    defer std.testing.allocator.free(after_failure.sent);
    try std.testing.expect(after_failure.result.full);
    try std.testing.expectEqual(@as(usize, 2), after_failure.sent.len);
}
