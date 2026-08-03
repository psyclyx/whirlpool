//! Whirlpool's renderer-facing scene boundary.
//!
//! Snail owns vector preparation and rasterization. Whirlpool owns the scene,
//! buffers, presentation API, graphics context, and frame scheduling. The CPU
//! backend gives this boundary deterministic pixel tests before a persistent
//! GPU atlas implementation is introduced.

const std = @import("std");
const snail = @import("snail");
const raster = @import("snail-raster");

const reference_width: f32 = 100;
const reference_height: f32 = 62.5;
const background = [4]u8{ 18, 12, 9, 255 };

pub const Scene = struct {
    allocator: std.mem.Allocator,
    pool: *snail.PagePool,
    atlas: snail.Atlas,
    device: raster.DeviceAtlas,
    binding: snail.render.records.Binding,
    shapes: [3]snail.Shape,
    instances: [3]snail.render.records.Instance = undefined,
    batches: [3]snail.render.records.DrawBatch = undefined,
    instance_len: usize = 0,
    batch_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Scene {
        var pool = try snail.PagePool.init(allocator, .{
            .max_pages = 2,
            .curve_words_per_page = 1 << 16,
            .band_words_per_page = 1 << 13,
        });
        errdefer pool.deinit();

        var atlas = try snail.Atlas.init(allocator, pool);
        errdefer atlas.deinit();

        const shapes = try buildShapes(allocator, &atlas);

        var device = try raster.DeviceAtlas.init(allocator, pool, .{
            .max_bindings = 1,
            .layer_info_height = 4,
            .max_images = 0,
        });
        errdefer device.deinit();
        var bindings: [1]snail.render.records.Binding = undefined;
        try device.upload(allocator, &.{&atlas}, &bindings);

        var self: Scene = .{
            .allocator = allocator,
            .pool = pool,
            .atlas = atlas,
            .device = device,
            .binding = bindings[0],
            .shapes = shapes,
        };
        _ = try snail.emit.emit(
            &self.instances,
            &self.batches,
            &self.instance_len,
            &self.batch_len,
            self.binding,
            &self.atlas,
            &self.shapes,
            .identity,
            .{ 1, 1, 1, 1 },
        );
        return self;
    }

    pub fn deinit(self: *Scene) void {
        self.device.deinit();
        self.atlas.deinit();
        self.pool.deinit();
    }

    pub fn render(self: *Scene, pixels: []u8, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const pixel_count = try std.math.mul(usize, width, height);
        const required = try std.math.mul(usize, pixel_count, 4);
        if (pixels.len != required) return error.InvalidBuffer;

        for (0..pixel_count) |index| {
            @memcpy(pixels[index * 4 ..][0..4], &background);
        }

        const stride = try std.math.mul(u32, width, 4);
        var renderer = try raster.Renderer.init(
            pixels,
            width,
            height,
            stride,
            .bgra8_unorm,
        );
        try raster.draw(
            &renderer,
            .{
                .mvp = snail.Mat4.ortho(
                    0,
                    reference_width,
                    reference_height,
                    0,
                    -1,
                    1,
                ),
                .surface = .{
                    .pixel_width = width,
                    .pixel_height = height,
                    .encoding = .srgb,
                    .format = .bgra8_unorm,
                },
                .raster = .{},
            },
            .{
                .instances = self.instances[0..self.instance_len],
                .batches = self.batches[0..self.batch_len],
            },
            &.{&self.device},
            null,
        );
    }
};

fn buildShapes(allocator: std.mem.Allocator, atlas: *snail.Atlas) ![3]snail.Shape {
    var panel = snail.Path.init(allocator);
    defer panel.deinit();
    try panel.addRoundedRect(.{ .x = 5, .y = 5, .w = 90, .h = 52.5 }, 4);
    const panel_shape = try addFill(
        allocator,
        atlas,
        &panel,
        .{ .namespace = snail.record_key.ns.path_fill, .a = 1 },
        .{ 0.055, 0.075, 0.115, 1.0 },
    );

    var accent = snail.Path.init(allocator);
    defer accent.deinit();
    try accent.addRoundedRect(.{ .x = 9, .y = 9, .w = 82, .h = 9 }, 2.5);
    const accent_shape = try addFill(
        allocator,
        atlas,
        &accent,
        .{ .namespace = snail.record_key.ns.path_fill, .a = 2 },
        snail.color.srgbToLinearColor(.{ 0.10, 0.62, 0.78, 1.0 }),
    );

    var current = snail.Path.init(allocator);
    defer current.deinit();
    try current.moveTo(.{ .x = 12, .y = 44 });
    try current.cubicTo(
        .{ .x = 29, .y = 18 },
        .{ .x = 48, .y = 55 },
        .{ .x = 63, .y = 31 },
    );
    try current.cubicTo(
        .{ .x = 74, .y = 15 },
        .{ .x = 84, .y = 29 },
        .{ .x = 89, .y = 24 },
    );
    const current_shape = try addStroke(
        allocator,
        atlas,
        &current,
        .{ .namespace = snail.record_key.ns.path_stroke, .a = 3 },
        .{
            .paint = .{ .solid = snail.color.srgbToLinearColor(.{ 0.48, 0.82, 0.96, 1.0 }) },
            .width = 1.8,
            .cap = .round,
            .join = .round,
        },
    );
    return .{ panel_shape, accent_shape, current_shape };
}

fn addFill(
    allocator: std.mem.Allocator,
    atlas: *snail.Atlas,
    path: *const snail.Path,
    key: snail.record_key.RecordKey,
    color: [4]f32,
) !snail.Shape {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var prepared = try path.prepare(allocator);
    defer prepared.deinit();
    var curves = try prepared.fillCurves(allocator, scratch.allocator());
    defer curves.deinit();
    try atlas.extendInPlace(allocator, .{ .entries = &.{.{ .geometry = .{
        .key = key,
        .curves = curves.view(),
        .paint = try prepared.paintForDesign(.{ .solid = color }),
    } }} });
    return .{ .key = key, .local_transform = prepared.placedBy(.identity) };
}

fn addStroke(
    allocator: std.mem.Allocator,
    atlas: *snail.Atlas,
    path: *const snail.Path,
    key: snail.record_key.RecordKey,
    style: snail.StrokeStyle,
) !snail.Shape {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var prepared = try path.prepare(allocator);
    defer prepared.deinit();
    var curves = try prepared.strokeCurves(allocator, scratch.allocator(), style);
    defer curves.deinit();
    try atlas.extendInPlace(allocator, .{ .entries = &.{.{ .geometry = .{
        .key = key,
        .curves = curves.view(),
        .paint = try prepared.paintForDesign(style.paint),
    } }} });
    return .{ .key = key, .local_transform = prepared.placedBy(.identity) };
}

test "Snail scene emits vector records and changes deterministic pixels" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();
    try std.testing.expectEqual(@as(usize, 3), scene.instance_len);
    try std.testing.expect(scene.batch_len >= 1);

    const width: u32 = 160;
    const height: u32 = 100;
    const pixels = try std.testing.allocator.alloc(u8, width * height * 4);
    defer std.testing.allocator.free(pixels);
    try scene.render(pixels, width, height);

    var changed: usize = 0;
    for (0..width * height) |index| {
        if (!std.mem.eql(u8, pixels[index * 4 ..][0..4], &background)) changed += 1;
    }
    try std.testing.expect(changed > width * height / 3);
    try std.testing.expect(changed < width * height);
}

test "render validates dimensions and exact caller-owned buffer size" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();
    var pixels: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidDimensions, scene.render(&pixels, 0, 1));
    try std.testing.expectError(error.InvalidBuffer, scene.render(&pixels, 2, 1));
}
