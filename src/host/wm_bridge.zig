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
    try result.operations.ensureTotalCapacity(allocator, plan.dimensionSlice().len * 2);
    for (plan.dimensionSlice()) |dimension| {
        const window = try resolver.window(resolver.context, dimension.window);
        if (dimension.size) |size| try result.operations.append(allocator, .{ .propose_dimensions = .{
            .window = window,
            .size = .{
                .width = try signedDimension(size.width),
                .height = try signedDimension(size.height),
            },
        } });
        switch (dimension.placement) {
            .unplaced, .scratchpad => {},
            .tiled => try result.operations.append(allocator, .{ .set_tiled = .{ .window = window, .edges = 0xf } }),
            .floating => try result.operations.append(allocator, .{ .set_tiled = .{ .window = window, .edges = 0 } }),
            .fullscreen => try result.operations.append(allocator, .{ .fullscreen = .{
                .window = window,
                .output = try resolver.output(resolver.context, plan.context.output),
            } }),
        }
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
    try result.operations.ensureTotalCapacity(allocator, plan.entrySlice().len * 6);
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
        try result.operations.append(allocator, .{
            .set_clip_box = .{
                .window = window,
                // A provider may describe a chrome-aware whole-window clip.
                // Otherwise its ordinary clip is content-relative and must not
                // be reused here: that would remove title and border extents.
                .box = if (entry.window_clip) |clip| try box(clip) else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            },
        });
        try result.operations.append(allocator, .{ .set_content_clip_box = .{
            .window = window,
            .box = if (entry.window_clip != null)
                .{ .x = 0, .y = 0, .width = 0, .height = 0 }
            else
                try box(entry.clip),
        } });
        if (entry.border) |border| try result.operations.append(allocator, .{ .set_borders = .{
            .window = window,
            .edges = border.edges,
            .width = border.width,
            .rgba = border.rgba,
        } });
    }
    const entries = plan.entrySlice();
    if (entries.len != 0) {
        const order = try allocator.alloc(usize, entries.len);
        defer allocator.free(order);
        for (order, 0..) |*index, value| index.* = value;
        // Layouts provide a total numeric stacking key. Preserve provider
        // order for equal keys so the lowering is deterministic.
        for (1..order.len) |index| {
            const wanted = order[index];
            var cursor = index;
            while (cursor > 0 and entries[order[cursor - 1]].z_index > entries[wanted].z_index) : (cursor -= 1) {
                order[cursor] = order[cursor - 1];
            }
            order[cursor] = wanted;
        }
        var previous: ?types.NodeId = null;
        for (order) |index| {
            const current = try resolver.node(resolver.context, entries[index].window);
            try result.operations.append(allocator, if (previous) |lower|
                .{ .place_above = .{ .node = current, .other = lower } }
            else
                .{ .place_bottom = current });
            previous = current;
        }
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
        },
    };
    defer plan.deinit();
    try plan.dimensions.append(allocator, .{
        .window = wm.WindowId.init(3, 2),
        .size = .{ .width = 800, .height = 600 },
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
        },
    };
    defer plan.deinit();
    try plan.entries.append(allocator, .{
        .window = wm.WindowId.init(2, 1),
        .screen = .{ .x = 4, .y = 8, .width = 10, .height = 10 },
        .clip = .{ .x = 4, .y = 8, .width = 10, .height = 10 },
        .visible = true,
    });
    const resolver = Resolver{ .window = FixtureResolver.window, .output = FixtureResolver.output, .node = FixtureResolver.node };
    var translated = try translateRender(allocator, &plan, resolver);
    defer translated.deinit();
    try std.testing.expectEqual(@as(usize, 5), translated.operations.items.len);
    try std.testing.expectEqual(@as(i32, 4), translated.operations.items[1].set_position.position.x);
    try std.testing.expectEqual(@as(i32, 0), translated.operations.items[2].set_clip_box.box.width);
    try std.testing.expectEqual(@as(i32, 0), translated.operations.items[2].set_clip_box.box.height);
    try std.testing.expectEqual(@as(i32, 4), translated.operations.items[3].set_content_clip_box.box.x);
    try std.testing.expectEqual(@as(i32, 10), translated.operations.items[3].set_content_clip_box.box.width);
}

test "whole-window clipping preserves chrome geometry instead of shrinking content borders" {
    const allocator = std.testing.allocator;
    var plan = wm.RenderPlan{
        .context = .{
            .allocator = allocator,
            .epoch = 1,
            .output = wm.OutputId.init(1, 1),
        },
    };
    defer plan.deinit();
    try plan.entries.append(allocator, .{
        .window = wm.WindowId.init(2, 1),
        .screen = .{ .x = 4, .y = 32, .width = 100, .height = 80 },
        .clip = .{ .x = 0, .y = 0, .width = 100, .height = 80 },
        .window_clip = .{ .x = -4, .y = -32, .width = 108, .height = 116 },
        .visible = true,
    });
    const resolver = Resolver{ .window = FixtureResolver.window, .output = FixtureResolver.output, .node = FixtureResolver.node };
    var translated = try translateRender(allocator, &plan, resolver);
    defer translated.deinit();
    try std.testing.expectEqual(@as(i32, -4), translated.operations.items[2].set_clip_box.box.x);
    try std.testing.expectEqual(@as(i32, -32), translated.operations.items[2].set_clip_box.box.y);
    try std.testing.expectEqual(@as(i32, 108), translated.operations.items[2].set_clip_box.box.width);
    try std.testing.expectEqual(@as(i32, 0), translated.operations.items[3].set_content_clip_box.box.width);
}

test "render translation applies the provider's stacking order" {
    const allocator = std.testing.allocator;
    var plan = wm.RenderPlan{ .context = .{
        .allocator = allocator,
        .epoch = 1,
        .output = wm.OutputId.init(1, 1),
    } };
    defer plan.deinit();
    for ([_]struct { window: wm.WindowId, z: i32 }{
        .{ .window = wm.WindowId.init(2, 1), .z = 20 },
        .{ .window = wm.WindowId.init(3, 1), .z = 10 },
    }) |entry| try plan.entries.append(allocator, .{
        .window = entry.window,
        .screen = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .clip = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .visible = true,
        .z_index = entry.z,
    });
    const resolver = Resolver{ .window = FixtureResolver.window, .output = FixtureResolver.output, .node = FixtureResolver.node };
    var translated = try translateRender(allocator, &plan, resolver);
    defer translated.deinit();
    try std.testing.expectEqual(types.NodeId.init(wm.WindowId.init(3, 1).raw()), translated.operations.items[8].place_bottom);
    try std.testing.expectEqual(types.NodeId.init(wm.WindowId.init(2, 1).raw()), translated.operations.items[9].place_above.node);
}
