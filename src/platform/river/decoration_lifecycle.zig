//! Pure WM-driven server-decoration selection and lifetime reconciliation.

const std = @import("std");
const wm = @import("whirlpool-wm");
const types = @import("whirlpool-host").types;

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

    /// Select only visible, managed, tiled leaf windows on each live output.
    /// Output order and window order are deterministic WM order, so proxy
    /// creation and destruction can be reconciled transactionally by callers.
    pub fn fromWorld(allocator: std.mem.Allocator, world: *const wm.World, output_ids: []const types.OutputId, context: ?*anyopaque, resolve_output: *const fn (?*anyopaque, types.OutputId) ?wm.OutputId, resolve_window: *const fn (?*anyopaque, wm.WindowId) ?types.WindowId) !SelectionSet {
        var result = SelectionSet.init(allocator);
        errdefer result.deinit();
        for (output_ids) |output_id| {
            const wm_output = resolve_output(context, output_id) orelse continue;
            const output = world.getOutput(wm_output) orelse continue;
            const tag = world.getTag(output.active_tag) orelse continue;
            var windows: std.ArrayList(types.WindowId) = .empty;
            errdefer windows.deinit(allocator);
            for (tag.columns.items) |column_id| {
                const column = world.getColumn(column_id) orelse continue;
                const root = column.root orelse continue;
                try collectLeaves(allocator, world, root, wm_output, context, resolve_window, &windows);
            }
            try result.outputs.append(allocator, .{ .output = output_id, .windows = try windows.toOwnedSlice(allocator) });
        }
        return result;
    }

    fn collectLeaves(allocator: std.mem.Allocator, world: *const wm.World, node_id: wm.NodeId, output: wm.OutputId, context: ?*anyopaque, resolve_window: *const fn (?*anyopaque, wm.WindowId) ?types.WindowId, result: *std.ArrayList(types.WindowId)) !void {
        const node = world.getNode(node_id) orelse return;
        if (node.isLeaf()) {
            const wm_window = node.window.?;
            const window = world.getWindow(wm_window) orelse return;
            if (window.lifecycle == .managed and window.placement == .tiled and window.output == output) {
                const live_window = resolve_window(context, wm_window) orelse return;
                try result.append(allocator, live_window);
            }
            return;
        }
        for (node.children.items) |child| try collectLeaves(allocator, world, child.id, output, context, resolve_window, result);
    }
};

pub const Lifetime = struct {
    active: std.AutoHashMap(types.WindowId, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Lifetime {
        return .{ .allocator = allocator, .active = .init(allocator) };
    }
    pub fn deinit(self: *Lifetime) void {
        self.active.deinit();
        self.* = undefined;
    }
    pub fn reconcile(self: *Lifetime, selected: []const types.WindowId, create: *const fn (?*anyopaque, types.WindowId) anyerror!void, destroy: *const fn (?*anyopaque, types.WindowId) anyerror!void, context: ?*anyopaque) !void {
        for (selected) |window| if (!self.active.contains(window)) {
            try create(context, window);
            self.active.put(window, {}) catch |err| {
                destroy(context, window) catch {};
                return err;
            };
        };
        var remove = std.ArrayList(types.WindowId).empty;
        defer remove.deinit(self.allocator);
        var iterator = self.active.keyIterator();
        while (iterator.next()) |window| {
            var found = false;
            for (selected) |candidate| if (candidate.value == window.value) {
                found = true;
                break;
            };
            if (!found) try remove.append(self.allocator, window.*);
        }
        for (remove.items) |window| {
            try destroy(context, window);
            _ = self.active.remove(window);
        }
    }
};

test "lifetime reconciles visible tiled leaves and tears down stale roles" {
    var lifetime = Lifetime.init(std.testing.allocator);
    defer lifetime.deinit();
    const Counter = struct { created: usize = 0, destroyed: usize = 0 };
    var counter = Counter{};
    const create = struct {
        fn f(raw: ?*anyopaque, _: types.WindowId) !void {
            @as(*Counter, @ptrCast(@alignCast(raw.?))).created += 1;
        }
    }.f;
    const destroy = struct {
        fn f(raw: ?*anyopaque, _: types.WindowId) !void {
            @as(*Counter, @ptrCast(@alignCast(raw.?))).destroyed += 1;
        }
    }.f;
    const first = types.WindowId.init(1);
    const second = types.WindowId.init(2);
    try lifetime.reconcile(&.{ first, second }, create, destroy, &counter);
    try lifetime.reconcile(&.{second}, create, destroy, &counter);
    try std.testing.expectEqual(@as(usize, 2), counter.created);
    try std.testing.expectEqual(@as(usize, 1), counter.destroyed);
}
