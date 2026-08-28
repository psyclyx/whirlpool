//! Owned staging queues for River events preceding manage_start/render_start.

const std = @import("std");
const types = @import("../types.zig");

fn OwnedBatch(comptime Fact: type) type {
    return struct {
        allocator: std.mem.Allocator,
        items: []Fact,

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.items);
            self.* = undefined;
        }

        pub fn facts(self: *const @This()) []const Fact {
            return self.items;
        }
    };
}

pub const ManageBatch = OwnedBatch(types.ManageFact);
pub const RenderBatch = OwnedBatch(types.RenderFact);

pub const StagedFacts = struct {
    allocator: std.mem.Allocator,
    manage: std.ArrayList(types.ManageFact) = .empty,
    render: std.ArrayList(types.RenderFact) = .empty,

    pub fn init(allocator: std.mem.Allocator) StagedFacts {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StagedFacts) void {
        self.manage.deinit(self.allocator);
        self.render.deinit(self.allocator);
    }

    pub fn stageManage(self: *StagedFacts, fact: types.ManageFact) !void {
        try self.manage.append(self.allocator, fact);
    }

    pub fn stageRender(self: *StagedFacts, fact: types.RenderFact) !void {
        try self.render.append(self.allocator, fact);
    }

    pub fn manageCount(self: *const StagedFacts) usize {
        return self.manage.items.len;
    }

    pub fn renderCount(self: *const StagedFacts) usize {
        return self.render.items.len;
    }

    /// Transfer the complete ordered manage change set to an immutable batch.
    pub fn takeManage(self: *StagedFacts) !ManageBatch {
        const items = try self.manage.toOwnedSlice(self.allocator);
        return .{ .allocator = self.allocator, .items = items };
    }

    /// Transfer dimensions accumulated for the next render_start.
    pub fn takeRender(self: *StagedFacts) !RenderBatch {
        const items = try self.render.toOwnedSlice(self.allocator);
        return .{ .allocator = self.allocator, .items = items };
    }

    pub fn clear(self: *StagedFacts) void {
        self.manage.clearRetainingCapacity();
        self.render.clearRetainingCapacity();
    }
};

test "manage facts preserve protocol order" {
    var staged = StagedFacts.init(std.testing.allocator);
    defer staged.deinit();

    const window = types.WindowId.init(4);
    try staged.stageManage(.{ .window_maximize_requested = window });
    try staged.stageManage(.{ .window_minimize_requested = window });

    var batch = try staged.takeManage();
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 0), staged.manageCount());
    try std.testing.expectEqual(@as(usize, 2), batch.facts().len);
    try std.testing.expectEqual(window, batch.facts()[0].window_maximize_requested);
    try std.testing.expectEqual(window, batch.facts()[1].window_minimize_requested);
}

test "manage and render staging are transferred independently" {
    var staged = StagedFacts.init(std.testing.allocator);
    defer staged.deinit();

    const window = types.WindowId.init(9);
    try staged.stageManage(.{ .window_closed = window });
    try staged.stageRender(.{ .window_dimensions = .{
        .window = window,
        .size = .{ .width = 800, .height = 600 },
    } });

    var manage = try staged.takeManage();
    defer manage.deinit();
    try std.testing.expectEqual(@as(usize, 1), staged.renderCount());

    var render = try staged.takeRender();
    defer render.deinit();
    try std.testing.expectEqual(@as(usize, 0), staged.renderCount());
    try std.testing.expectEqual(@as(i32, 800), render.facts()[0].window_dimensions.size.width);
}
