//! Platform-neutral River render coordination.
//!
//! Concrete hosts supply request callbacks. This module owns the atomic
//! surface-commit prefix and finish guarantee without importing Wayland, Lua,
//! UI, or graphics implementations.

const std = @import("std");
const types = @import("../types.zig");

pub const SurfaceRole = union(enum) {
    shell: types.ShellSurfaceId,
    decoration: types.DecorationId,
};

/// Opaque hand-off from a retained presenter. The presenter alone interprets
/// `token`; generation makes stale or reordered submissions detectable.
pub const SubmittedCommit = struct {
    role: SurfaceRole,
    generation: u64,
    token: u64,
};

pub const Emitter = struct {
    context: ?*anyopaque = null,
    prepare_surface: *const fn (?*anyopaque, SubmittedCommit) anyerror!void,
    /// Preflight must already have resolved this role. No failure is legal
    /// once synchronized commits begin.
    sync_surface: *const fn (?*anyopaque, SurfaceRole) void,
    /// Issues only prevalidated, allocation-free presentation/commit
    /// requests. It must not call Lua or wait for the GPU/compositor.
    commit_surface: *const fn (?*anyopaque, SubmittedCommit) void,
    render_operation: *const fn (?*anyopaque, types.RenderOperation) anyerror!void,
    finish_render: *const fn (?*anyopaque) anyerror!void,
};

/// Validate every submitted surface before promising a synchronized commit,
/// then order role sync, surface commit, River requests, and render_finish.
/// Bare sync operations are rejected: each promise must have a buffer commit.
pub fn runRender(
    plan: types.RenderPlan,
    commits: []const SubmittedCommit,
    emitter: Emitter,
) anyerror!void {
    var operation_error: ?anyerror = null;

    for (plan.operations) |operation| switch (operation) {
        .decoration_sync_next_commit, .shell_surface_sync_next_commit => {
            operation_error = error.UnpairedSurfaceSync;
            break;
        },
        else => {},
    };

    if (operation_error == null) {
        for (commits) |commit| {
            if (commit.generation == 0 or commit.token == 0) {
                operation_error = error.InvalidSubmittedCommit;
                break;
            }
            emitter.prepare_surface(emitter.context, commit) catch |err| {
                operation_error = err;
                break;
            };
        }
    }

    if (operation_error == null) {
        for (commits) |commit| {
            emitter.sync_surface(emitter.context, commit.role);
            emitter.commit_surface(emitter.context, commit);
        }
    }

    if (operation_error == null) {
        for (plan.operations) |operation| {
            emitter.render_operation(emitter.context, operation) catch |err| {
                operation_error = err;
                break;
            };
        }
    }

    try emitter.finish_render(emitter.context);
    if (operation_error) |err| return err;
}

const Trace = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(u8) = .empty,
    fail_prepare: bool = false,

    fn add(raw: ?*anyopaque, value: u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try self.items.append(self.allocator, value);
    }
    fn prepare(raw: ?*anyopaque, _: SubmittedCommit) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try add(raw, 'p');
        if (self.fail_prepare) return error.SurfaceNotReady;
    }
    fn sync(raw: ?*anyopaque, _: SurfaceRole) void {
        add(raw, 's') catch unreachable;
    }
    fn commit(raw: ?*anyopaque, _: SubmittedCommit) void {
        add(raw, 'c') catch unreachable;
    }
    fn render(raw: ?*anyopaque, _: types.RenderOperation) !void {
        try add(raw, 'r');
    }
    fn finish(raw: ?*anyopaque) !void {
        try add(raw, 'R');
    }
    fn emitter(self: *@This()) Emitter {
        return .{
            .context = self,
            .prepare_surface = prepare,
            .sync_surface = sync,
            .commit_surface = commit,
            .render_operation = render,
            .finish_render = finish,
        };
    }
};

test "surface commits precede render requests and finish" {
    var trace = Trace{ .allocator = std.testing.allocator };
    defer trace.items.deinit(trace.allocator);
    try runRender(
        .{ .operations = &.{.{ .show = types.WindowId.init(3) }} },
        &.{.{ .role = .{ .decoration = types.DecorationId.init(8) }, .generation = 4, .token = 9 }},
        trace.emitter(),
    );
    try std.testing.expectEqualSlices(u8, "pscrR", trace.items.items);
}

test "failed preparation sends no sync or commit but still finishes" {
    var trace = Trace{ .allocator = std.testing.allocator, .fail_prepare = true };
    defer trace.items.deinit(trace.allocator);
    try std.testing.expectError(error.SurfaceNotReady, runRender(
        .{ .operations = &.{} },
        &.{.{ .role = .{ .shell = types.ShellSurfaceId.init(2) }, .generation = 1, .token = 1 }},
        trace.emitter(),
    ));
    try std.testing.expectEqualSlices(u8, "pR", trace.items.items);
}

test "bare sync is rejected and render still finishes" {
    var trace = Trace{ .allocator = std.testing.allocator };
    defer trace.items.deinit(trace.allocator);
    try std.testing.expectError(error.UnpairedSurfaceSync, runRender(
        .{ .operations = &.{.{ .decoration_sync_next_commit = types.DecorationId.init(7) }} },
        &.{},
        trace.emitter(),
    ));
    try std.testing.expectEqualSlices(u8, "R", trace.items.items);
}
