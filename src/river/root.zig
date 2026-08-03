//! Replayable core of the River protocol adapter.
//!
//! A concrete Wayland bridge combines protocol callbacks with policy defaults,
//! normalizes them into `Event` values, and executes the returned effects. This
//! half deliberately owns no proxies or sockets, making captured event streams
//! deterministic unit tests.

const std = @import("std");
const model = @import("whirlpool-model");

pub const transaction = @import("transaction.zig");

pub const Event = union(enum) {
    output_announced: struct {
        id: model.OutputId,
        active_tags: model.Tags,
    },
    output_removed: model.OutputId,
    window_announced: struct {
        id: model.WindowId,
        output: ?model.OutputId,
        tags: model.Tags,
    },
    window_mapped: model.WindowId,
    window_close_started: model.WindowId,
    window_removed: model.WindowId,
    focus_requested: model.WindowId,
    active_tags_changed: struct {
        output: model.OutputId,
        tags: model.Tags,
    },
    window_tags_changed: struct {
        window: model.WindowId,
        tags: model.Tags,
    },
    window_output_changed: struct {
        window: model.WindowId,
        output: ?model.OutputId,
    },
    placement_requested: struct {
        window: model.WindowId,
        placement: model.Placement,
    },
};

pub const FocusEffect = struct {
    output: model.OutputId,
    window: ?model.WindowId,
};

pub const Effects = struct {
    focus_storage: [2]FocusEffect = undefined,
    focus_len: u2 = 0,

    pub fn focusChanges(self: *const Effects) []const FocusEffect {
        return self.focus_storage[0..self.focus_len];
    }

    fn appendFocus(self: *Effects, effect: FocusEffect) void {
        std.debug.assert(self.focus_len < self.focus_storage.len);
        self.focus_storage[self.focus_len] = effect;
        self.focus_len += 1;
    }
};

pub const Adapter = struct {
    state: model.Model,

    pub fn init(allocator: std.mem.Allocator) Adapter {
        return .{ .state = model.Model.init(allocator) };
    }

    pub fn deinit(self: *Adapter) void {
        self.state.deinit();
    }

    pub fn apply(self: *Adapter, event: Event) !Effects {
        const watched = self.watchedFocus(event);
        try self.applyUnchecked(event);

        var effects: Effects = .{};
        for (watched.entries[0..watched.len]) |before| {
            const after = self.state.getOutput(before.output) orelse continue;
            if (after.focused != before.focused) {
                effects.appendFocus(.{ .output = after.id, .window = after.focused });
            }
        }
        return effects;
    }

    fn applyUnchecked(self: *Adapter, event: Event) !void {
        switch (event) {
            .output_announced => |value| try self.state.addOutput(.{
                .id = value.id,
                .active_tags = value.active_tags,
            }),
            .output_removed => |id| try self.state.removeOutput(id),
            .window_announced => |value| try self.state.addWindow(.{
                .id = value.id,
                .output = value.output,
                .tags = value.tags,
            }),
            .window_mapped => |id| try self.state.manageWindow(id),
            .window_close_started => |id| try self.state.beginClose(id),
            .window_removed => |id| try self.state.removeWindow(id),
            .focus_requested => |id| try self.state.focus(id),
            .active_tags_changed => |value| try self.state.setActiveTags(value.output, value.tags),
            .window_tags_changed => |value| try self.state.setWindowTags(value.window, value.tags),
            .window_output_changed => |value| try self.state.moveWindow(value.window, value.output),
            .placement_requested => |value| try self.state.setPlacement(value.window, value.placement),
        }
    }

    fn watchedFocus(self: *const Adapter, event: Event) WatchedFocus {
        var watched: WatchedFocus = .{};
        switch (event) {
            .output_removed, .output_announced, .window_announced, .window_mapped, .placement_requested => {},
            .window_close_started, .window_removed, .focus_requested => |id| {
                if (self.state.getWindow(id)) |window| watched.add(&self.state, window.output);
            },
            .window_tags_changed => |value| {
                if (self.state.getWindow(value.window)) |window| watched.add(&self.state, window.output);
            },
            .active_tags_changed => |value| watched.add(&self.state, value.output),
            .window_output_changed => |value| {
                if (self.state.getWindow(value.window)) |window| watched.add(&self.state, window.output);
                watched.add(&self.state, value.output);
            },
        }
        return watched;
    }
};

const WatchedFocus = struct {
    const Entry = struct {
        output: model.OutputId,
        focused: ?model.WindowId,
    };

    entries: [2]Entry = undefined,
    len: u2 = 0,

    fn add(self: *WatchedFocus, state: *const model.Model, maybe_output: ?model.OutputId) void {
        const output_id = maybe_output orelse return;
        for (self.entries[0..self.len]) |entry| {
            if (entry.output == output_id) return;
        }
        const output = state.getOutput(output_id) orelse return;
        std.debug.assert(self.len < self.entries.len);
        self.entries[self.len] = .{ .output = output_id, .focused = output.focused };
        self.len += 1;
    }
};

fn wid(value: u64) model.WindowId {
    return @enumFromInt(value);
}

fn oid(value: u64) model.OutputId {
    return @enumFromInt(value);
}

fn applyAll(adapter: *Adapter, events: []const Event) !void {
    for (events) |event| _ = try adapter.apply(event);
}

test "captured focus and tag events emit only observable focus changes" {
    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    const both: model.Tags = .{ .bits = model.Tags.single(0).bits | model.Tags.single(1).bits };
    try applyAll(&adapter, &.{
        .{ .output_announced = .{ .id = oid(1), .active_tags = both } },
        .{ .window_announced = .{ .id = wid(10), .output = oid(1), .tags = model.Tags.single(0) } },
        .{ .window_announced = .{ .id = wid(20), .output = oid(1), .tags = model.Tags.single(1) } },
        .{ .window_mapped = wid(10) },
        .{ .window_mapped = wid(20) },
    });

    const first = try adapter.apply(.{ .focus_requested = wid(10) });
    try std.testing.expectEqualSlices(FocusEffect, &.{.{ .output = oid(1), .window = wid(10) }}, first.focusChanges());
    const repeated = try adapter.apply(.{ .focus_requested = wid(10) });
    try std.testing.expectEqual(@as(usize, 0), repeated.focusChanges().len);
    const second = try adapter.apply(.{ .focus_requested = wid(20) });
    try std.testing.expectEqualSlices(FocusEffect, &.{.{ .output = oid(1), .window = wid(20) }}, second.focusChanges());
    const tags = try adapter.apply(.{ .active_tags_changed = .{
        .output = oid(1),
        .tags = model.Tags.single(0),
    } });
    try std.testing.expectEqualSlices(FocusEffect, &.{.{ .output = oid(1), .window = wid(10) }}, tags.focusChanges());
    try adapter.state.validate();
}

test "moving a focused window reports source repair and destination focus" {
    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    try applyAll(&adapter, &.{
        .{ .output_announced = .{ .id = oid(1), .active_tags = model.Tags.single(0) } },
        .{ .output_announced = .{ .id = oid(2), .active_tags = model.Tags.single(0) } },
        .{ .window_announced = .{ .id = wid(10), .output = oid(1), .tags = model.Tags.single(0) } },
        .{ .window_announced = .{ .id = wid(20), .output = oid(1), .tags = model.Tags.single(0) } },
        .{ .window_mapped = wid(10) },
        .{ .window_mapped = wid(20) },
        .{ .focus_requested = wid(10) },
    });

    const effects = try adapter.apply(.{ .window_output_changed = .{
        .window = wid(10),
        .output = oid(2),
    } });
    try std.testing.expectEqualSlices(FocusEffect, &.{
        .{ .output = oid(1), .window = wid(20) },
        .{ .output = oid(2), .window = wid(10) },
    }, effects.focusChanges());
    try adapter.state.validate();
}

test "failed protocol events neither mutate state nor emit effects" {
    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    _ = try adapter.apply(.{ .output_announced = .{
        .id = oid(1),
        .active_tags = model.Tags.single(0),
    } });

    try std.testing.expectError(error.UnknownWindow, adapter.apply(.{ .focus_requested = wid(99) }));
    try std.testing.expectEqual(@as(usize, 0), adapter.state.windows.items.len);
    try std.testing.expectEqual(@as(?model.WindowId, null), adapter.state.getOutput(oid(1)).?.focused);
    try adapter.state.validate();
}
