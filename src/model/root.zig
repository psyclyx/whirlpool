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
    try model.addWindow(.{ .id = wid(10), .output = oid(1), .tags = Tags.single(0), .lifecycle = .managed });
    try model.addWindow(.{ .id = wid(20), .output = oid(1), .tags = Tags.single(1), .lifecycle = .managed });

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
    try model.addWindow(.{ .id = wid(10), .output = oid(1), .tags = Tags.single(0), .lifecycle = .managed });
    try model.addWindow(.{ .id = wid(20), .output = oid(1), .tags = Tags.single(0), .lifecycle = .managed });
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
    try model.addWindow(.{ .id = wid(10), .output = oid(1), .tags = Tags.single(0), .lifecycle = .managed });
    try model.addWindow(.{ .id = wid(20), .output = oid(1), .tags = Tags.single(0), .lifecycle = .managed });
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
    try model.addWindow(.{ .id = wid(10), .output = oid(1), .tags = Tags.single(0), .lifecycle = .managed });
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
