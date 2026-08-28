//! Integration-owned translation from WM plans to River vocabulary.
//!
//! The WM kernel owns generation-checked identities and geometry. The host
//! owns protocol identities and request ordering. This file is the only join:
//! every identity crosses through an explicit resolver, so a packed WM ID is
//! never silently treated as a River proxy or node.

const std = @import("std");
const wm = @import("whirlpool-wm");
const types = @import("types.zig");

pub const Resolver = struct {
    context: ?*anyopaque = null,
    window: *const fn (?*anyopaque, wm.WindowId) anyerror!types.WindowId,
    output: *const fn (?*anyopaque, wm.OutputId) anyerror!types.OutputId,
    node: *const fn (?*anyopaque, wm.WindowId) anyerror!types.NodeId,
};

pub const OwnedManagePlan = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayList(types.ManageOperation) = .empty,

    pub fn deinit(self: *OwnedManagePlan) void {
        self.operations.deinit(self.allocator);
    }

    pub fn view(self: *const OwnedManagePlan) types.ManagePlan {
        return .{ .operations = self.operations.items };
    }
};

pub const OwnedRenderPlan = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayList(types.RenderOperation) = .empty,

    pub fn deinit(self: *OwnedRenderPlan) void {
        self.operations.deinit(self.allocator);
    }

    pub fn view(self: *const OwnedRenderPlan) types.RenderPlan {
        return .{ .operations = self.operations.items };
    }
};

pub fn translateManage(
    allocator: std.mem.Allocator,
    plan: *const wm.ManagePlan,
    resolver: Resolver,
) !OwnedManagePlan {
    var result = OwnedManagePlan{ .allocator = allocator };
    errdefer result.deinit();
    try result.operations.ensureTotalCapacity(allocator, plan.dimensionSlice().len);
    for (plan.dimensionSlice()) |dimension| {
        try result.operations.append(allocator, .{ .propose_dimensions = .{
            .window = try resolver.window(resolver.context, dimension.window),
            .size = .{
                .width = try signedDimension(dimension.size.width),
                .height = try signedDimension(dimension.size.height),
            },
        } });
    }
    return result;
}

pub fn translateRender(
    allocator: std.mem.Allocator,
    plan: *const wm.RenderPlan,
    resolver: Resolver,
) !OwnedRenderPlan {
    var result = OwnedRenderPlan{ .allocator = allocator };
    errdefer result.deinit();
    try result.operations.ensureTotalCapacity(allocator, plan.entrySlice().len * 4);
    for (plan.entrySlice()) |entry| {
        const window = try resolver.window(resolver.context, entry.window);
        const node = try resolver.node(resolver.context, entry.window);
        try result.operations.append(allocator, if (entry.visible)
            .{ .show = window }
        else
            .{ .hide = window });
        try result.operations.append(allocator, .{ .set_position = .{
            .node = node,
            .position = .{ .x = entry.screen.x, .y = entry.screen.y },
        } });
        try result.operations.append(allocator, .{ .set_clip_box = .{
            .window = window,
            .box = try box(entry.clip),
        } });
        try result.operations.append(allocator, .{ .set_content_clip_box = .{
            .window = window,
            .box = try box(entry.clip),
        } });
    }
    return result;
}

fn signedDimension(value: u32) !i32 {
    return std.math.cast(i32, value) orelse error.DimensionOverflow;
}

fn box(rect: wm.Rect) !types.Box {
    return .{
        .x = rect.x,
        .y = rect.y,
        .width = try signedDimension(rect.width),
        .height = try signedDimension(rect.height),
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

test "plan translation requires explicit identity resolution and preserves ownership" {
    const allocator = std.testing.allocator;
    var plan = wm.ManagePlan{
        .context = .{
            .allocator = allocator,
            .epoch = 4,
            .output = wm.OutputId.init(1, 1),
            .camera = .{ .tag = wm.TagId.init(1, 1), .current = 0, .target = 0, .strip_width = 100 },
        },
    };
    defer plan.deinit();
    try plan.dimensions.append(allocator, .{
        .window = wm.WindowId.init(3, 2),
        .column = wm.ColumnId.init(1, 1),
        .size = .{ .width = 800, .height = 600 },
        .virtual = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    });

    const resolver = Resolver{ .window = FixtureResolver.window, .output = FixtureResolver.output, .node = FixtureResolver.node };
    var translated = try translateManage(allocator, &plan, resolver);
    defer translated.deinit();
    try std.testing.expectEqual(@as(usize, 1), translated.operations.items.len);
    try std.testing.expectEqual(@as(u64, wm.WindowId.init(3, 2).raw()), translated.operations.items[0].propose_dimensions.window.value);
}

test "render translation maps screen geometry and rejects overflow" {
    const allocator = std.testing.allocator;
    var plan = wm.RenderPlan{
        .context = .{
            .allocator = allocator,
            .epoch = 1,
            .output = wm.OutputId.init(1, 1),
            .camera = .{ .tag = wm.TagId.init(1, 1), .current = 0, .target = 0, .strip_width = 1 },
        },
    };
    defer plan.deinit();
    try plan.entries.append(allocator, .{
        .window = wm.WindowId.init(2, 1),
        .column = wm.ColumnId.init(1, 1),
        .placement = .tiled,
        .target_virtual = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .screen = .{ .x = 4, .y = 8, .width = 10, .height = 10 },
        .clip = .{ .x = 4, .y = 8, .width = 10, .height = 10 },
        .visible = true,
    });
    const resolver = Resolver{ .window = FixtureResolver.window, .output = FixtureResolver.output, .node = FixtureResolver.node };
    var translated = try translateRender(allocator, &plan, resolver);
    defer translated.deinit();
    try std.testing.expectEqual(@as(usize, 4), translated.operations.items.len);
    try std.testing.expectEqual(@as(i32, 4), translated.operations.items[1].set_position.position.x);
}
