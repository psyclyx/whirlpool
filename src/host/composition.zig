//! Host-owned composition of an immutable WM snapshot and River plan values.
//!
//! The kernel remains pure and the River bridge remains the only owner of
//! protocol identities.  This small join is deliberately boring: it takes a
//! callback-lifetime snapshot, builds both geometry plans from that same
//! revision, and lowers them through the explicit host resolver.  A caller
//! cannot accidentally translate manage and render plans from different WM
//! epochs.

const std = @import("std");
const wm = @import("whirlpool-wm");
const bridge = @import("wm/bridge.zig");
const types = @import("types.zig");

pub const FramePlans = struct {
    allocator: std.mem.Allocator,
    epoch: u64,
    manage: wm.ManagePlan,
    render: wm.RenderPlan,
    river_manage: bridge.OwnedManagePlan,
    river_render: bridge.OwnedRenderPlan,

    pub fn deinit(self: *FramePlans) void {
        self.river_render.deinit();
        self.river_manage.deinit();
        self.render.deinit();
        self.manage.deinit();
        self.* = undefined;
    }
};

/// Translate one provider-produced plan pair through the host identity seam.
pub fn translateFrame(
    allocator: std.mem.Allocator,
    input: wm.LayoutPlans,
    resolver: bridge.Resolver,
) !FramePlans {
    var manage = input.manage;
    errdefer manage.deinit();
    var render = input.render;
    errdefer render.deinit();

    // Both builders consumed the same snapshot epoch. Keep the assertion
    // local to the join so future builders cannot silently drift apart.
    if (manage.context.epoch != render.context.epoch) return error.PlanEpochMismatch;

    var river_manage = try bridge.translateManage(allocator, &manage, resolver);
    errdefer river_manage.deinit();
    var river_render = try bridge.translateRender(allocator, &render, resolver);
    errdefer river_render.deinit();

    return .{
        .allocator = allocator,
        .epoch = manage.context.epoch,
        .manage = manage,
        .render = render,
        .river_manage = river_manage,
        .river_render = river_render,
    };
}

const FixtureResolver = struct {
    fn window(_: ?*anyopaque, id: wm.WindowId) !types.WindowId {
        if (!id.isValid()) return error.InvalidIdentity;
        return types.WindowId.init(id.raw());
    }

    fn output(_: ?*anyopaque, id: wm.OutputId) !types.OutputId {
        if (!id.isValid()) return error.InvalidIdentity;
        return types.OutputId.init(id.raw());
    }

    fn node(_: ?*anyopaque, id: wm.WindowId) !types.NodeId {
        if (!id.isValid()) return error.InvalidIdentity;
        return types.NodeId.init(id.raw());
    }
};

test "frame composition translates one WM epoch into both River plans" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .usable = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    const column = try world.createColumn(tag, .{});
    const window = try world.createWindow(.{ .tag = tag, .output = output });
    try world.manageWindow(window, column);

    const resolver = bridge.Resolver{
        .window = FixtureResolver.window,
        .output = FixtureResolver.output,
        .node = FixtureResolver.node,
    };
    var snapshot = world.view();
    const output_value = snapshot.getOutput(output).?;
    const tag_value = snapshot.getTag(output_value.active_tag).?;
    const camera: wm.CameraTarget = .{ .tag = tag_value.id, .current = 0, .target = 0, .strip_width = 800 };
    var input: wm.LayoutPlans = .{
        .manage = .{ .context = .{ .allocator = std.testing.allocator, .epoch = snapshot.epoch(), .output = output, .camera = camera } },
        .render = .{ .context = .{ .allocator = std.testing.allocator, .epoch = snapshot.epoch(), .output = output, .camera = camera } },
    };
    try input.manage.dimensions.append(std.testing.allocator, .{
        .window = window,
        .column = column,
        .size = .{ .width = 800, .height = 600 },
        .virtual = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });
    try input.render.entries.append(std.testing.allocator, .{
        .window = window,
        .column = column,
        .placement = .tiled,
        .target_virtual = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .screen = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .clip = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .visible = true,
    });
    var frame = try translateFrame(std.testing.allocator, input, resolver);
    defer frame.deinit();

    try std.testing.expectEqual(world.epoch(), frame.epoch);
    try std.testing.expectEqual(frame.manage.context.epoch, frame.render.context.epoch);
    try std.testing.expectEqual(frame.manage.dimensionSlice().len, frame.river_manage.operations.items.len);
    try std.testing.expectEqual(@as(usize, 4), frame.river_render.operations.items.len);
}

test "frame composition rejects mismatched provider epochs" {
    var world = wm.World.init(std.testing.allocator);
    defer world.deinit();
    const tag = try world.createTag();
    const output = try world.createOutput(.{
        .active_tag = tag,
        .bounds = .{ .x = 0, .y = 0, .width = 320, .height = 240 },
        .usable = .{ .x = 0, .y = 0, .width = 320, .height = 240 },
    });
    _ = try world.createColumn(tag, .{});
    const resolver = bridge.Resolver{
        .window = FixtureResolver.window,
        .output = FixtureResolver.output,
        .node = FixtureResolver.node,
    };
    var snapshot = world.view();
    const output_value = snapshot.getOutput(output).?;
    const camera: wm.CameraTarget = .{ .tag = output_value.active_tag, .current = 0, .target = 0, .strip_width = 0 };
    const input: wm.LayoutPlans = .{
        .manage = .{ .context = .{ .allocator = std.testing.allocator, .epoch = snapshot.epoch(), .output = output, .camera = camera } },
        .render = .{ .context = .{ .allocator = std.testing.allocator, .epoch = snapshot.epoch() + 1, .output = output, .camera = camera } },
    };
    try std.testing.expectError(error.PlanEpochMismatch, translateFrame(std.testing.allocator, input, resolver));
}
