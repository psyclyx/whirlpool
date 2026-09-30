//! Pure WM-driven server-decoration selection.

const std = @import("std");
const wm = @import("whirlpool-wm");
const types = @import("types.zig");

pub const Selection = struct {
    output: types.OutputId,
    windows: []types.WindowId,
};

pub const SelectionSet = struct {
    allocator: std.mem.Allocator,
    outputs: std.ArrayList(Selection) = .empty,

    pub fn init(allocator: std.mem.Allocator) SelectionSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SelectionSet) void {
        for (self.outputs.items) |item| self.allocator.free(item.windows);
        self.outputs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Select managed tiled windows belonging to each output's active tag.
    /// Visibility and clipping remain properties of the layout plan; this
    /// selection only controls which concrete window resources own decoration
    /// surfaces. Output and window order are deterministic WM order.
    pub fn fromWorld(allocator: std.mem.Allocator, world: *const wm.World, output_ids: []const types.OutputId, context: ?*anyopaque, resolve_output: *const fn (?*anyopaque, types.OutputId) ?wm.OutputId, resolve_window: *const fn (?*anyopaque, wm.WindowId) ?types.WindowId) !SelectionSet {
        var result = SelectionSet.init(allocator);
        errdefer result.deinit();
        for (output_ids) |output_id| {
            const wm_output = resolve_output(context, output_id) orelse continue;
            const output = world.getOutput(wm_output) orelse continue;
            var windows: std.ArrayList(types.WindowId) = .empty;
            errdefer windows.deinit(allocator);
            var window_index: usize = 0;
            while (world.windowAt(window_index)) |window_id| : (window_index += 1) {
                const window = world.getWindow(window_id) orelse continue;
                if (window.lifecycle != .managed) continue;
                if (window.tag != output.active_tag) continue;
                const live_window = resolve_window(context, window_id) orelse continue;
                try windows.append(allocator, live_window);
            }
            try result.outputs.append(allocator, .{ .output = output_id, .windows = try windows.toOwnedSlice(allocator) });
        }
        return result;
    }
};

const TestMap = struct {
    outputs: [3]wm.OutputId,
    windows: [8]wm.WindowId,
    window_count: usize = 0,

    fn output(raw: ?*anyopaque, id: types.OutputId) ?wm.OutputId {
        const self: *const TestMap = @ptrCast(@alignCast(raw.?));
        return self.outputs[id.value - 1];
    }

    fn window(raw: ?*anyopaque, id: wm.WindowId) ?types.WindowId {
        const self: *const TestMap = @ptrCast(@alignCast(raw.?));
        for (self.windows[0..self.window_count], 0..) |candidate, index|
            if (candidate == id) return types.WindowId.init(@intCast(index + 1));
        return null;
    }
};

test "every output's active-tag windows are selected, not just the first tag's" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: wm.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    var map: TestMap = .{ .outputs = undefined, .windows = undefined };
    var tags: [5]wm.TagId = undefined;
    for (&tags) |*tag| tag.* = try world.createTag();
    // Output 0 shows tag 1; outputs 1 and 2 show tags 3 and 5.
    const shown = [_]wm.TagId{ tags[0], tags[2], tags[4] };
    for (&map.outputs, shown) |*output, tag|
        output.* = try world.createOutput(.{ .active_tag = tag, .bounds = rect, .usable = rect });
    // One window on each shown tag, plus one on a tag nobody shows.
    const placements = [_]struct { tag: wm.TagId, output: usize }{
        .{ .tag = tags[0], .output = 0 },
        .{ .tag = tags[2], .output = 1 },
        .{ .tag = tags[4], .output = 2 },
        .{ .tag = tags[1], .output = 0 },
    };
    for (placements) |placement| {
        const window = try world.createWindow(.{ .tag = placement.tag });
        try world.manageWindow(window);
        map.windows[map.window_count] = window;
        map.window_count += 1;
    }

    const ids = [_]types.OutputId{ types.OutputId.init(1), types.OutputId.init(2), types.OutputId.init(3) };
    var selection = try SelectionSet.fromWorld(std.testing.allocator, &world, &ids, &map, TestMap.output, TestMap.window);
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 3), selection.outputs.items.len);
    for (selection.outputs.items, 0..) |item, index| {
        try std.testing.expectEqual(@as(usize, 1), item.windows.len);
        try std.testing.expectEqual(types.WindowId.init(@intCast(index + 1)), item.windows[0]);
    }
}

test "switching an output's tag switches its selected windows" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const rect: wm.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const first = try world.createTag();
    const second = try world.createTag();
    var map: TestMap = .{ .outputs = undefined, .windows = undefined };
    map.outputs[0] = try world.createOutput(.{ .active_tag = first, .bounds = rect, .usable = rect });
    for ([_]wm.TagId{ first, second }) |tag| {
        const window = try world.createWindow(.{ .tag = tag });
        try world.manageWindow(window);
        map.windows[map.window_count] = window;
        map.window_count += 1;
    }
    _ = try world.applyAtomically(&.{.{ .tag = .{ .activate = .{ .output = map.outputs[0], .tag = second } } }});

    const ids = [_]types.OutputId{types.OutputId.init(1)};
    var selection = try SelectionSet.fromWorld(std.testing.allocator, &world, &ids, &map, TestMap.output, TestMap.window);
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 1), selection.outputs.items[0].windows.len);
    try std.testing.expectEqual(types.WindowId.init(2), selection.outputs.items[0].windows[0]);
}
