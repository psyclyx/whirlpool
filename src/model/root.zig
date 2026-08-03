//! Pure Whirlpool window state.
//!
//! Protocol objects, rendering handles, and file descriptors do not belong
//! here. Adapters translate external events into these operations and render
//! the resulting state. Keeping that direction strict makes the hard window
//! behavior deterministic and cheap to test.

const std = @import("std");

pub const WindowId = enum(u64) { _ };
pub const OutputId = enum(u64) { _ };

pub const Tags = packed struct(u32) {
    bits: u32,

    pub const none: Tags = .{ .bits = 0 };

    pub fn single(index: u5) Tags {
        return .{ .bits = @as(u32, 1) << index };
    }

    pub fn intersects(a: Tags, b: Tags) bool {
        return a.bits & b.bits != 0;
    }
};

pub const Lifecycle = enum { announced, managed, closing };
pub const Placement = enum { tiled, floating, fullscreen };

pub const Window = struct {
    id: WindowId,
    output: ?OutputId,
    tags: Tags,
    lifecycle: Lifecycle = .announced,
    placement: Placement = .tiled,
    focus_serial: u64 = 0,
};

pub const Output = struct {
    id: OutputId,
    active_tags: Tags,
    focused: ?WindowId = null,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window) = .empty,
    outputs: std.ArrayList(Output) = .empty,
    next_focus_serial: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        self.windows.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
    }

    pub fn addOutput(self: *Model, output: Output) !void {
        if (output.active_tags.bits == 0) return error.EmptyActiveTags;
        if (output.focused != null) return error.InvalidInitialOutputState;
        if (self.outputIndex(output.id) != null) return error.DuplicateOutput;
        try self.outputs.append(self.allocator, output);
    }

    pub fn removeOutput(self: *Model, id: OutputId) !void {
        const index = self.outputIndex(id) orelse return error.UnknownOutput;
        _ = self.outputs.orderedRemove(index);
        for (self.windows.items) |*window| {
            if (window.output == id) window.output = null;
        }
    }

    pub fn addWindow(self: *Model, window: Window) !void {
        if (window.lifecycle != .announced or window.focus_serial != 0) {
            return error.InvalidInitialWindowState;
        }
        if (self.windowIndex(window.id) != null) return error.DuplicateWindow;
        if (window.output) |id| {
            if (self.outputIndex(id) == null) return error.UnknownOutput;
        }
        try self.windows.append(self.allocator, window);
    }

    pub fn manageWindow(self: *Model, id: WindowId) !void {
        const window = self.findWindow(id) orelse return error.UnknownWindow;
        if (window.lifecycle != .announced) return error.InvalidLifecycle;
        window.lifecycle = .managed;
    }

    pub fn beginClose(self: *Model, id: WindowId) !void {
        const window = self.findWindow(id) orelse return error.UnknownWindow;
        if (window.lifecycle != .managed) return error.InvalidLifecycle;
        const output = window.output;
        window.lifecycle = .closing;
        if (output) |output_id| self.repairFocus(output_id);
    }

    pub fn removeWindow(self: *Model, id: WindowId) !void {
        const index = self.windowIndex(id) orelse return error.UnknownWindow;
        const output = self.windows.items[index].output;
        _ = self.windows.orderedRemove(index);
        if (output) |output_id| self.repairFocus(output_id);
    }

    pub fn focus(self: *Model, id: WindowId) !void {
        const window = self.findWindow(id) orelse return error.UnknownWindow;
        const output_id = window.output orelse return error.WindowNotVisible;
        const output = self.findOutput(output_id) orelse return error.UnknownOutput;
        if (!isVisibleOn(window.*, output.*)) return error.WindowNotVisible;

        window.focus_serial = self.next_focus_serial;
        self.next_focus_serial +|= 1;
        output.focused = id;
    }

    pub fn setActiveTags(self: *Model, id: OutputId, tags: Tags) !void {
        if (tags.bits == 0) return error.EmptyActiveTags;
        const output = self.findOutput(id) orelse return error.UnknownOutput;
        output.active_tags = tags;
        self.repairFocus(id);
    }

    pub fn setWindowTags(self: *Model, id: WindowId, tags: Tags) !void {
        const window = self.findWindow(id) orelse return error.UnknownWindow;
        const output = window.output;
        window.tags = tags;
        if (output) |output_id| self.repairFocus(output_id);
    }

    pub fn moveWindow(self: *Model, id: WindowId, destination: ?OutputId) !void {
        if (destination) |output_id| {
            if (self.outputIndex(output_id) == null) return error.UnknownOutput;
        }
        const window = self.findWindow(id) orelse return error.UnknownWindow;
        const previous = window.output;
        window.output = destination;
        if (previous) |output_id| self.repairFocus(output_id);
        if (destination) |output_id| self.repairFocus(output_id);
    }

    pub fn setPlacement(self: *Model, id: WindowId, placement: Placement) !void {
        const window = self.findWindow(id) orelse return error.UnknownWindow;
        if (window.lifecycle != .managed) return error.InvalidLifecycle;
        window.placement = placement;
    }

    pub fn getWindow(self: *const Model, id: WindowId) ?Window {
        return if (self.findWindowConst(id)) |value| value.* else null;
    }

    pub fn getOutput(self: *const Model, id: OutputId) ?Output {
        return if (self.findOutputConst(id)) |value| value.* else null;
    }

    pub fn isVisible(self: *const Model, id: WindowId) bool {
        const window = self.findWindowConst(id) orelse return false;
        const output_id = window.output orelse return false;
        const output = self.findOutputConst(output_id) orelse return false;
        return isVisibleOn(window.*, output.*);
    }

    pub fn validate(self: *const Model) !void {
        for (self.outputs.items, 0..) |output, i| {
            if (output.active_tags.bits == 0) return error.EmptyActiveTags;
            for (self.outputs.items[i + 1 ..]) |other| {
                if (other.id == output.id) return error.DuplicateOutput;
            }
            if (output.focused) |focused| {
                const window = self.findWindowConst(focused) orelse return error.DanglingFocus;
                if (!isVisibleOn(window.*, output)) return error.DanglingFocus;
            }
        }
        for (self.windows.items, 0..) |window, i| {
            for (self.windows.items[i + 1 ..]) |other| {
                if (other.id == window.id) return error.DuplicateWindow;
            }
            if (window.output) |output_id| {
                if (self.findOutputConst(output_id) == null) return error.DanglingOutput;
            }
        }
    }

    fn repairFocus(self: *Model, output_id: OutputId) void {
        const output = self.findOutput(output_id) orelse return;
        if (output.focused) |focused| {
            if (self.findWindowConst(focused)) |window| {
                if (isVisibleOn(window.*, output.*)) return;
            }
        }

        var candidate: ?Window = null;
        for (self.windows.items) |window| {
            if (!isVisibleOn(window, output.*)) continue;
            if (candidate == null or window.focus_serial > candidate.?.focus_serial) {
                candidate = window;
            }
        }
        output.focused = if (candidate) |window| window.id else null;
    }

    fn findWindow(self: *Model, id: WindowId) ?*Window {
        const index = self.windowIndex(id) orelse return null;
        return &self.windows.items[index];
    }

    fn findWindowConst(self: *const Model, id: WindowId) ?*const Window {
        const index = self.windowIndex(id) orelse return null;
        return &self.windows.items[index];
    }

    fn findOutput(self: *Model, id: OutputId) ?*Output {
        const index = self.outputIndex(id) orelse return null;
        return &self.outputs.items[index];
    }

    fn findOutputConst(self: *const Model, id: OutputId) ?*const Output {
        const index = self.outputIndex(id) orelse return null;
        return &self.outputs.items[index];
    }

    fn windowIndex(self: *const Model, id: WindowId) ?usize {
        for (self.windows.items, 0..) |window, i| if (window.id == id) return i;
        return null;
    }

    fn outputIndex(self: *const Model, id: OutputId) ?usize {
        for (self.outputs.items, 0..) |output, i| if (output.id == id) return i;
        return null;
    }
};

fn isVisibleOn(window: Window, output: Output) bool {
    return window.lifecycle == .managed and
        window.output == output.id and
        window.tags.intersects(output.active_tags);
}

fn wid(value: u64) WindowId {
    return @enumFromInt(value);
}

fn oid(value: u64) OutputId {
    return @enumFromInt(value);
}

fn addManagedWindow(
    model: *Model,
    id: WindowId,
    output: ?OutputId,
    tags: Tags,
) !void {
    try model.addWindow(.{ .id = id, .output = output, .tags = tags });
    try model.manageWindow(id);
}

test "announced windows are inert until managed" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(0) });
    try model.addWindow(.{ .id = wid(10), .output = oid(1), .tags = Tags.single(0) });

    try std.testing.expect(!model.isVisible(wid(10)));
    try std.testing.expectError(error.WindowNotVisible, model.focus(wid(10)));
    try model.manageWindow(wid(10));
    try std.testing.expect(model.isVisible(wid(10)));
    try model.validate();
}

test "tag changes repair focus to the most recently focused visible window" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(0) });
    try addManagedWindow(&model, wid(10), oid(1), Tags.single(0));
    try addManagedWindow(&model, wid(20), oid(1), Tags.single(1));

    try model.focus(wid(10));
    try model.setActiveTags(oid(1), Tags.single(1));
    try std.testing.expectEqual(wid(20), model.findOutputConst(oid(1)).?.focused.?);
    try model.focus(wid(20));
    try model.setActiveTags(oid(1), .{ .bits = Tags.single(0).bits | Tags.single(1).bits });
    try std.testing.expectEqual(wid(20), model.findOutputConst(oid(1)).?.focused.?);
    try model.validate();
}

test "closing a focused window repairs focus before protocol destruction" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(0) });
    try addManagedWindow(&model, wid(10), oid(1), Tags.single(0));
    try addManagedWindow(&model, wid(20), oid(1), Tags.single(0));
    try model.focus(wid(10));
    try model.focus(wid(20));

    try model.beginClose(wid(20));
    try std.testing.expectEqual(wid(10), model.findOutputConst(oid(1)).?.focused.?);
    try std.testing.expect(!model.isVisible(wid(20)));
    try model.removeWindow(wid(20));
    try model.validate();
}

test "moving the focused window repairs both outputs" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(0) });
    try model.addOutput(.{ .id = oid(2), .active_tags = Tags.single(0) });
    try addManagedWindow(&model, wid(10), oid(1), Tags.single(0));
    try addManagedWindow(&model, wid(20), oid(1), Tags.single(0));
    try model.focus(wid(10));

    try model.moveWindow(wid(10), oid(2));
    try std.testing.expectEqual(wid(20), model.findOutputConst(oid(1)).?.focused.?);
    try std.testing.expectEqual(wid(10), model.findOutputConst(oid(2)).?.focused.?);
    try model.validate();
}

test "output removal orphans windows without dangling focus" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(0) });
    try addManagedWindow(&model, wid(10), oid(1), Tags.single(0));
    try model.focus(wid(10));

    try model.removeOutput(oid(1));
    try std.testing.expectEqual(@as(?OutputId, null), model.findWindowConst(wid(10)).?.output);
    try std.testing.expect(!model.isVisible(wid(10)));
    try model.validate();
}

test "invalid identities, lifecycles, outputs, and empty active tags are rejected" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expectError(error.EmptyActiveTags, model.addOutput(.{ .id = oid(1), .active_tags = .none }));
    try model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(0) });
    try std.testing.expectError(error.DuplicateOutput, model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(1) }));
    try std.testing.expectError(error.UnknownOutput, model.addWindow(.{ .id = wid(10), .output = oid(9), .tags = Tags.single(0) }));
    try model.addWindow(.{ .id = wid(10), .output = oid(1), .tags = Tags.single(0) });
    try std.testing.expectError(error.DuplicateWindow, model.addWindow(.{ .id = wid(10), .output = null, .tags = Tags.single(0) }));
    try model.manageWindow(wid(10));
    try std.testing.expectError(error.InvalidLifecycle, model.manageWindow(wid(10)));
    try model.beginClose(wid(10));
    try std.testing.expectError(error.InvalidLifecycle, model.beginClose(wid(10)));
    try std.testing.expectError(error.EmptyActiveTags, model.setActiveTags(oid(1), .none));
    try model.validate();
}

test "initial state cannot bypass focus and lifecycle transitions" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();

    try std.testing.expectError(error.InvalidInitialOutputState, model.addOutput(.{
        .id = oid(1),
        .active_tags = Tags.single(0),
        .focused = wid(10),
    }));
    try model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(0) });
    try std.testing.expectError(error.InvalidInitialWindowState, model.addWindow(.{
        .id = wid(10),
        .output = oid(1),
        .tags = Tags.single(0),
        .lifecycle = .managed,
    }));
    try std.testing.expectError(error.InvalidInitialWindowState, model.addWindow(.{
        .id = wid(10),
        .output = oid(1),
        .tags = Tags.single(0),
        .focus_serial = 9,
    }));
    try std.testing.expectEqual(@as(usize, 0), model.windows.items.len);
    try model.validate();
}

test "placement changes require a managed window" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addOutput(.{ .id = oid(1), .active_tags = Tags.single(0) });
    try model.addWindow(.{ .id = wid(10), .output = oid(1), .tags = Tags.single(0) });

    try std.testing.expectError(error.InvalidLifecycle, model.setPlacement(wid(10), .floating));
    try model.manageWindow(wid(10));
    try model.setPlacement(wid(10), .fullscreen);
    try std.testing.expectEqual(Placement.fullscreen, model.getWindow(wid(10)).?.placement);
    try model.validate();
}

test "long mixed transition sequences preserve every model invariant" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    var state: u64 = 0x6f_63_65_61_6e;

    for (0..10_000) |_| {
        const value = nextPseudoRandom(&state);
        const window_id = wid(1 + value % 12);
        const output_id = oid(1 + (value >> 8) % 4);
        const tags = Tags.single(@intCast((value >> 16) % 8));

        switch ((value >> 24) % 11) {
            0 => model.addOutput(.{ .id = output_id, .active_tags = tags }) catch {},
            1 => model.removeOutput(output_id) catch {},
            2 => model.addWindow(.{
                .id = window_id,
                .output = if (value & 1 == 0) output_id else null,
                .tags = tags,
            }) catch {},
            3 => model.manageWindow(window_id) catch {},
            4 => model.beginClose(window_id) catch {},
            5 => model.removeWindow(window_id) catch {},
            6 => model.focus(window_id) catch {},
            7 => model.setActiveTags(output_id, tags) catch {},
            8 => model.setWindowTags(window_id, if (value & 2 == 0) tags else .none) catch {},
            9 => model.moveWindow(window_id, if (value & 4 == 0) output_id else null) catch {},
            10 => model.setPlacement(window_id, @enumFromInt((value >> 32) % 3)) catch {},
            else => unreachable,
        }
        try model.validate();
    }
}

fn nextPseudoRandom(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.*;
}
