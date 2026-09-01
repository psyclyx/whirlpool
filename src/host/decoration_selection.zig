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
                if (window.output != wm_output or window.tag != output.active_tag) continue;
                const live_window = resolve_window(context, window_id) orelse continue;
                try windows.append(allocator, live_window);
            }
            try result.outputs.append(allocator, .{ .output = output_id, .windows = try windows.toOwnedSlice(allocator) });
        }
        return result;
    }
};
