//! Deterministic geometry policy for Whirlpool windows.
//!
//! This module reads the pure model and writes caller-owned arrangements. It
//! has no River objects, which keeps layout edge cases out of protocol code.

const std = @import("std");
const model = @import("whirlpool-model");

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Arrangement = struct {
    window: model.WindowId,
    rect: Rect,
};

/// Arrange visible tiled windows in a master/stack split. Floating windows are
/// deliberately absent: their user-controlled geometry belongs to a separate
/// placement store. The most recently focused fullscreen window suppresses all
/// other arrangements on the output.
pub fn arrange(
    state: *const model.Model,
    output_id: model.OutputId,
    bounds: Rect,
    gap: u32,
    storage: []Arrangement,
) ![]Arrangement {
    if (bounds.width == 0 or bounds.height == 0) return error.EmptyBounds;
    _ = state.getOutput(output_id) orelse return error.UnknownOutput;

    var fullscreen: ?model.Window = null;
    var tiled_count: usize = 0;
    for (state.windows.items) |window| {
        if (window.output != output_id) continue;
        if (!state.isVisible(window.id)) continue;
        switch (window.placement) {
            .fullscreen => {
                if (fullscreen == null or window.focus_serial > fullscreen.?.focus_serial) {
                    fullscreen = window;
                }
            },
            .tiled => tiled_count += 1,
            .floating => {},
        }
    }

    if (fullscreen) |window| {
        if (storage.len < 1) return error.BufferTooSmall;
        storage[0] = .{ .window = window.id, .rect = bounds };
        return storage[0..1];
    }
    if (storage.len < tiled_count) return error.BufferTooSmall;
    if (tiled_count == 0) return storage[0..0];

    const content = try inset(bounds, gap);
    if (tiled_count == 1) {
        for (state.windows.items) |window| {
            if (window.output == output_id and state.isVisible(window.id) and window.placement == .tiled) {
                storage[0] = .{ .window = window.id, .rect = content };
                return storage[0..1];
            }
        }
        unreachable;
    }

    if (content.width < 2) return error.BoundsTooSmall;
    const column_gap = @min(gap, content.width - 2);
    const usable_width = content.width - column_gap;
    const master_width = usable_width / 2;
    const stack_width = usable_width - master_width;
    const stack_x = try addCoordinate(content.x, master_width + column_gap);
    const stack_count = tiled_count - 1;
    if (content.height < stack_count) return error.BoundsTooSmall;
    const row_gap = if (stack_count <= 1)
        0
    else
        @min(gap, (content.height - @as(u32, @intCast(stack_count))) / @as(u32, @intCast(stack_count - 1)));
    const rows_height = content.height - row_gap * @as(u32, @intCast(stack_count - 1));
    const base_height = rows_height / @as(u32, @intCast(stack_count));
    const extra_rows = rows_height % @as(u32, @intCast(stack_count));

    var output_index: usize = 0;
    var stack_index: usize = 0;
    var stack_y = content.y;
    for (state.windows.items) |window| {
        if (window.output != output_id) continue;
        if (!state.isVisible(window.id) or window.placement != .tiled) continue;
        if (output_index == 0) {
            storage[0] = .{ .window = window.id, .rect = .{
                .x = content.x,
                .y = content.y,
                .width = master_width,
                .height = content.height,
            } };
        } else {
            const height = base_height + @as(u32, @intFromBool(stack_index < extra_rows));
            storage[output_index] = .{ .window = window.id, .rect = .{
                .x = stack_x,
                .y = stack_y,
                .width = stack_width,
                .height = height,
            } };
            stack_y = try addCoordinate(stack_y, height + row_gap);
            stack_index += 1;
        }
        output_index += 1;
    }
    return storage[0..output_index];
}

fn inset(bounds: Rect, requested: u32) !Rect {
    const max_gap = (@min(bounds.width, bounds.height) - 1) / 2;
    const gap = @min(requested, max_gap);
    return .{
        .x = try addCoordinate(bounds.x, gap),
        .y = try addCoordinate(bounds.y, gap),
        .width = bounds.width - gap * 2,
        .height = bounds.height - gap * 2,
    };
}

fn addCoordinate(value: i32, offset: u32) !i32 {
    if (offset > std.math.maxInt(i32)) return error.GeometryOverflow;
    return std.math.add(i32, value, @intCast(offset));
}

fn wid(value: u64) model.WindowId {
    return @enumFromInt(value);
}

fn oid(value: u64) model.OutputId {
    return @enumFromInt(value);
}

fn addManaged(
    state: *model.Model,
    id: model.WindowId,
    output: model.OutputId,
    tags: model.Tags,
) !void {
    try state.addWindow(.{ .id = id, .output = output, .tags = tags });
    try state.manageWindow(id);
}

test "master stack tiles every pixel deterministically" {
    var state = model.Model.init(std.testing.allocator);
    defer state.deinit();
    try state.addOutput(.{ .id = oid(1), .active_tags = model.Tags.single(0) });
    try addManaged(&state, wid(10), oid(1), model.Tags.single(0));
    try addManaged(&state, wid(20), oid(1), model.Tags.single(0));
    try addManaged(&state, wid(30), oid(1), model.Tags.single(0));

    var storage: [3]Arrangement = undefined;
    const result = try arrange(&state, oid(1), .{ .x = 10, .y = 20, .width = 101, .height = 81 }, 5, &storage);
    try std.testing.expectEqualSlices(Arrangement, &.{
        .{ .window = wid(10), .rect = .{ .x = 15, .y = 25, .width = 43, .height = 71 } },
        .{ .window = wid(20), .rect = .{ .x = 63, .y = 25, .width = 43, .height = 33 } },
        .{ .window = wid(30), .rect = .{ .x = 63, .y = 63, .width = 43, .height = 33 } },
    }, result);
}

test "visibility floating and closing state are excluded from tiling" {
    var state = model.Model.init(std.testing.allocator);
    defer state.deinit();
    try state.addOutput(.{ .id = oid(1), .active_tags = model.Tags.single(0) });
    try state.addOutput(.{ .id = oid(2), .active_tags = model.Tags.single(0) });
    try addManaged(&state, wid(10), oid(1), model.Tags.single(0));
    try addManaged(&state, wid(20), oid(1), model.Tags.single(1));
    try addManaged(&state, wid(30), oid(1), model.Tags.single(0));
    try state.setPlacement(wid(30), .floating);
    try addManaged(&state, wid(40), oid(1), model.Tags.single(0));
    try state.beginClose(wid(40));
    try addManaged(&state, wid(50), oid(2), model.Tags.single(0));
    try state.setPlacement(wid(50), .fullscreen);

    var storage: [4]Arrangement = undefined;
    const result = try arrange(&state, oid(1), .{ .x = 0, .y = 0, .width = 80, .height = 60 }, 4, &storage);
    try std.testing.expectEqualSlices(Arrangement, &.{.{
        .window = wid(10),
        .rect = .{ .x = 4, .y = 4, .width = 72, .height = 52 },
    }}, result);
}

test "most recently focused fullscreen window suppresses the tile plan" {
    var state = model.Model.init(std.testing.allocator);
    defer state.deinit();
    try state.addOutput(.{ .id = oid(1), .active_tags = model.Tags.single(0) });
    try addManaged(&state, wid(10), oid(1), model.Tags.single(0));
    try addManaged(&state, wid(20), oid(1), model.Tags.single(0));
    try addManaged(&state, wid(30), oid(1), model.Tags.single(0));
    try state.setPlacement(wid(20), .fullscreen);
    try state.setPlacement(wid(30), .fullscreen);
    try state.focus(wid(20));
    try state.focus(wid(30));

    var storage: [3]Arrangement = undefined;
    const bounds: Rect = .{ .x = -100, .y = 40, .width = 1920, .height = 1080 };
    const result = try arrange(&state, oid(1), bounds, 20, &storage);
    try std.testing.expectEqualSlices(Arrangement, &.{.{ .window = wid(30), .rect = bounds }}, result);
}

test "tiny bounds and caller storage fail without partial output" {
    var state = model.Model.init(std.testing.allocator);
    defer state.deinit();
    try state.addOutput(.{ .id = oid(1), .active_tags = model.Tags.single(0) });
    try addManaged(&state, wid(10), oid(1), model.Tags.single(0));
    try addManaged(&state, wid(20), oid(1), model.Tags.single(0));
    var one: [1]Arrangement = undefined;
    try std.testing.expectError(error.BufferTooSmall, arrange(
        &state,
        oid(1),
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        2,
        &one,
    ));
    var two: [2]Arrangement = undefined;
    try std.testing.expectError(error.BoundsTooSmall, arrange(
        &state,
        oid(1),
        .{ .x = 0, .y = 0, .width = 1, .height = 10 },
        0,
        &two,
    ));
    try std.testing.expectError(error.EmptyBounds, arrange(
        &state,
        oid(1),
        .{ .x = 0, .y = 0, .width = 0, .height = 10 },
        0,
        &two,
    ));
}
