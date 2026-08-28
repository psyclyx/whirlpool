//! Transport-neutral named-action IPC boundary.
//!
//! This module validates the small control vocabulary and translates accepted
//! requests into lifecycle intents. It deliberately owns no socket, process,
//! or Lua handle. The runtime must perform the requested effect and feed the
//! resulting lifecycle event back to `lifecycle.Controller`.

const std = @import("std");
const lifecycle = @import("lifecycle.zig");

pub const MaxActionNameBytes = 16;

pub const Action = enum {
    introspect,
    reload,
    stop,

    pub fn name(self: Action) []const u8 {
        return switch (self) {
            .introspect => "introspect",
            .reload => "reload",
            .stop => "stop",
        };
    }
};

pub const Request = struct {
    id: u64,
    action: Action,

    pub fn parse(id: u64, action_name: []const u8) error{
        InvalidRequestId,
        EmptyAction,
        ActionNameTooLong,
        UnknownAction,
    }!Request {
        if (id == 0) return error.InvalidRequestId;
        if (action_name.len == 0) return error.EmptyAction;
        if (action_name.len > MaxActionNameBytes) return error.ActionNameTooLong;

        const action: Action = if (std.mem.eql(u8, action_name, "introspect"))
            .introspect
        else if (std.mem.eql(u8, action_name, "reload"))
            .reload
        else if (std.mem.eql(u8, action_name, "stop"))
            .stop
        else
            return error.UnknownAction;

        return .{ .id = id, .action = action };
    }
};

pub const RejectReason = enum {
    invalid_lifecycle,
};

pub const Accepted = struct {
    id: u64,
    state: lifecycle.State,
    revision: u64,
};

pub const Rejected = struct {
    id: u64,
    reason: RejectReason,
    snapshot: lifecycle.Snapshot,
};

pub const Introspection = struct {
    id: u64,
    snapshot: lifecycle.Snapshot,
};

pub const Reply = union(enum) {
    accepted: Accepted,
    introspection: Introspection,
    rejected: Rejected,
};

pub const Endpoint = struct {
    controller: *lifecycle.Controller,

    pub fn init(controller: *lifecycle.Controller) Endpoint {
        return .{ .controller = controller };
    }

    /// Accepting reload/stop records only the intent. The accepted response
    /// therefore reports a pending state until the runtime observes the real
    /// process transition.
    pub fn handle(self: *Endpoint, request: Request) Reply {
        return switch (request.action) {
            .introspect => .{ .introspection = .{
                .id = request.id,
                .snapshot = self.controller.snapshot(),
            } },
            .reload => self.accept(request.id, .reload_requested),
            .stop => self.accept(request.id, .stop_requested),
        };
    }

    fn accept(self: *Endpoint, id: u64, event: lifecycle.Event) Reply {
        self.controller.observe(event) catch {
            return .{ .rejected = .{
                .id = id,
                .reason = .invalid_lifecycle,
                .snapshot = self.controller.snapshot(),
            } };
        };
        const snapshot = self.controller.snapshot();
        return .{ .accepted = .{
            .id = id,
            .state = snapshot.state,
            .revision = snapshot.revision,
        } };
    }
};

test "named actions are exact and bounded" {
    const introspect = try Request.parse(1, "introspect");
    try std.testing.expectEqual(Action.introspect, introspect.action);
    try std.testing.expectEqualStrings("reload", Action.reload.name());
    try std.testing.expectError(error.InvalidRequestId, Request.parse(0, "reload"));
    try std.testing.expectError(error.EmptyAction, Request.parse(2, ""));
    try std.testing.expectError(error.UnknownAction, Request.parse(3, "Reload"));
    try std.testing.expectError(error.ActionNameTooLong, Request.parse(4, "0123456789abcdef0"));
}

test "endpoint exposes introspection and rejects duplicate control intents" {
    var controller: lifecycle.Controller = .{};
    var endpoint = Endpoint.init(&controller);

    const initial = endpoint.handle(try Request.parse(1, "introspect"));
    switch (initial) {
        .introspection => |reply| {
            try std.testing.expectEqual(@as(u64, 1), reply.id);
            try std.testing.expectEqual(lifecycle.State.stopped, reply.snapshot.state);
        },
        else => return error.UnexpectedReply,
    }

    try controller.observe(.start_requested);
    try controller.observe(.started);
    const start = endpoint.handle(try Request.parse(2, "reload"));
    switch (start) {
        .accepted => |accepted| {
            try std.testing.expectEqual(@as(u64, 2), accepted.id);
            try std.testing.expectEqual(lifecycle.State.reload_pending, accepted.state);
        },
        else => return error.UnexpectedReply,
    }

    const duplicate = endpoint.handle(try Request.parse(3, "reload"));
    switch (duplicate) {
        .rejected => |rejected| {
            try std.testing.expectEqual(RejectReason.invalid_lifecycle, rejected.reason);
            try std.testing.expectEqual(lifecycle.State.reload_pending, rejected.snapshot.state);
        },
        else => return error.UnexpectedReply,
    }
}

test "stop intent is accepted only while the runtime can stop" {
    var controller: lifecycle.Controller = .{};
    var endpoint = Endpoint.init(&controller);

    const rejected = endpoint.handle(try Request.parse(1, "stop"));
    switch (rejected) {
        .rejected => |reply| try std.testing.expectEqual(RejectReason.invalid_lifecycle, reply.reason),
        else => return error.UnexpectedReply,
    }

    try controller.observe(.start_requested);
    try controller.observe(.started);
    const accepted = endpoint.handle(try Request.parse(2, "stop"));
    switch (accepted) {
        .accepted => |reply| try std.testing.expectEqual(lifecycle.State.stopping, reply.state),
        else => return error.UnexpectedReply,
    }
}
