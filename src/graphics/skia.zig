//! C-ABI membrane for the Skia renderer.
//!
//! Skia owns text rasterization and 2D drawing. Only scalar values, bounded
//! borrowed geometry, and a borrowed pixel frame cross the C++ boundary.
//! Vulkan upload and presentation remain entirely in the Wayland WSI owner.

const std = @import("std");

const Native = opaque {};

extern fn whirlpool_skia_create(bgra: c_int) ?*Native;
extern fn whirlpool_skia_create_vulkan(instance: *anyopaque, physical_device: *anyopaque, device: *anyopaque, queue: *anyopaque, queue_family: u32) ?*Native;
extern fn whirlpool_skia_destroy(renderer: *Native) void;
extern fn whirlpool_skia_begin(renderer: *Native, width: u32, height: u32) c_int;
extern fn whirlpool_skia_clear(renderer: *Native, r: f32, g: f32, b: f32, a: f32) void;
extern fn whirlpool_skia_draw_rect(renderer: *Native, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn whirlpool_skia_draw_rect_radial(renderer: *Native, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32, cr: f32, cg: f32, cb: f32, ca: f32) void;

fn drawRectNative(native: *Native, rect: Rect, radius: f32, color: Color, center: ?Color) void {
    if (center) |inner| {
        whirlpool_skia_draw_rect_radial(native, rect.x, rect.y, rect.width, rect.height, radius, color.r, color.g, color.b, color.a, inner.r, inner.g, inner.b, inner.a);
    } else whirlpool_skia_draw_rect(native, rect.x, rect.y, rect.width, rect.height, radius, color.r, color.g, color.b, color.a);
}
extern fn whirlpool_skia_draw_polygon(renderer: *Native, points: [*]const f32, point_count: usize, r: f32, g: f32, b: f32, a: f32) void;
extern fn whirlpool_skia_draw_polygon_gradient(renderer: *Native, points: [*]const f32, point_count: usize, gradient: [*]const u8, gradient_length: usize, left: f32, bottom: f32, opacity: f32) void;
extern fn whirlpool_skia_draw_text(renderer: *Native, family: [*]const u8, family_length: usize, text: [*]const u8, length: usize, x: f32, y: f32, size: f32, r: f32, g: f32, b: f32, a: f32, anchor: c_int, middle: c_int) void;
extern fn whirlpool_skia_draw_icon(renderer: *Native, source: [*]const u8, length: usize, x: f32, y: f32, width: f32, height: f32, opacity: f32) void;
extern fn whirlpool_skia_set_icon_wake(renderer: *Native, wake: ?*const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) void;
extern fn whirlpool_skia_wait_icons(renderer: *Native) c_int;
extern fn whirlpool_skia_push_clip(renderer: *Native, x: f32, y: f32, width: f32, height: f32) void;
extern fn whirlpool_skia_push_clip_polygon(renderer: *Native, points: [*]const f32, point_count: usize) void;
extern fn whirlpool_skia_pop_clip(renderer: *Native) void;
extern fn whirlpool_skia_end(renderer: *Native, row_bytes: *usize) ?[*]const u8;
extern fn whirlpool_skia_begin_vulkan(renderer: *Native, width: u32, height: u32, image: *anyopaque, memory: *anyopaque, memory_size: u64, format: u32, layout: u32, queue_family: u32) c_int;
extern fn whirlpool_skia_end_vulkan(renderer: *Native, final_layout: u32, final_queue_family: u32) c_int;
extern fn whirlpool_skia_measure_text(renderer: *Native, family: [*]const u8, family_length: usize, text: [*]const u8, length: usize, size: f32) f32;
extern fn whirlpool_skia_fit_text(renderer: *Native, family: [*]const u8, family_length: usize, text: [*]const u8, length: usize, size: f32, max_width: f32) usize;

/// Widths of text as a renderer draws it (its fonts, fallback included).
/// Borrowed from, and only valid as long as, that renderer.
pub const TextMetrics = struct {
    native: *Native,

    /// `family` is a font family name; empty for the default.
    pub fn width(self: TextMetrics, family: []const u8, text: []const u8, size: f32) f32 {
        if (text.len == 0) return 0;
        return whirlpool_skia_measure_text(self.native, family.ptr, family.len, text.ptr, text.len, size);
    }

    /// Bytes of the longest prefix of `text` (whole characters) at most
    /// `max_width` wide.
    pub fn fit(self: TextMetrics, family: []const u8, text: []const u8, size: f32, max_width: f32) usize {
        if (text.len == 0) return 0;
        return @min(text.len, whirlpool_skia_fit_text(self.native, family.ptr, family.len, text.ptr, text.len, size, max_width));
    }
};

pub const Frame = struct {
    pixels: [*]const u8,
    byte_len: usize,
    width: u32,
    height: u32,
    row_bytes: usize,
};

/// Called on the icon loader's thread when an icon a renderer drew while it
/// was still loading is ready: its owner should draw again. It must not call
/// back into the renderer.
pub const IconWake = struct {
    context: ?*anyopaque,
    run: *const fn (?*anyopaque) callconv(.c) void,
};

pub const Renderer = struct {
    native: *Native,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(bgra: bool) !Renderer {
        return .{ .native = whirlpool_skia_create(@intFromBool(bgra)) orelse return error.SkiaInitFailed };
    }

    pub fn deinit(self: *Renderer) void {
        whirlpool_skia_destroy(self.native);
        self.* = undefined;
    }

    pub fn textMetrics(self: *const Renderer) TextMetrics {
        return .{ .native = self.native };
    }

    pub fn begin(self: *Renderer, width: u32, height: u32, clear: [4]f32) !void {
        const result = whirlpool_skia_begin(self.native, width, height);
        if (result != 0) return error.SkiaBeginFailed;
        self.width = width;
        self.height = height;
        whirlpool_skia_clear(self.native, clear[0], clear[1], clear[2], clear[3]);
    }

    pub fn drawRect(self: *Renderer, rect: Rect, radius: f32, color: Color) void {
        whirlpool_skia_draw_rect(self.native, rect.x, rect.y, rect.width, rect.height, radius, color.r, color.g, color.b, color.a);
    }

    pub fn drawPolygon(self: *Renderer, polygon: Polygon, color: Color) void {
        drawPolygonNative(self.native, polygon, color);
    }

    pub fn drawText(self: *Renderer, text: []const u8, x: f32, baseline: f32, size: f32, color: Color) void {
        whirlpool_skia_draw_text(self.native, "", 0, text.ptr, text.len, x, baseline, size, color.r, color.g, color.b, color.a, 0, 0);
    }

    pub fn drawTextItem(self: *Renderer, item: anytype) void {
        drawTextNative(self.native, item);
    }

    /// Icons load on a worker thread: one not loaded yet draws nothing.
    pub fn drawIcon(self: *Renderer, source: []const u8, rect: Rect, opacity: f32) void {
        whirlpool_skia_draw_icon(self.native, source.ptr, source.len, rect.x, rect.y, rect.width, rect.height, opacity);
    }

    /// For offline rendering only: if the last frame met icons still
    /// loading, wait for them and return true (draw it again to show them).
    pub fn waitForIcons(self: *Renderer) bool {
        return whirlpool_skia_wait_icons(self.native) != 0;
    }

    /// Consume renderer-neutral operations emitted by the retained UI host.
    /// The list owns neither text nor renderer resources; callers keep it
    /// alive until this function returns.
    pub fn drawList(self: *Renderer, list: DrawList) void {
        for (list.ops) |op| switch (op) {
            .rect => |rect| drawRectNative(self.native, rect.rect, rect.radius, rect.color, rect.center),
            .polygon => |item| drawPolygonOp(self.native, item),
            .text => |item| self.drawTextItem(item),
            .icon => |item| self.drawIcon(item.source, item.rect, item.opacity),
            .push_clip => |rect| whirlpool_skia_push_clip(self.native, rect.x, rect.y, rect.width, rect.height),
            .push_clip_polygon => |polygon| whirlpool_skia_push_clip_polygon(self.native, @ptrCast(&polygon.points[0]), polygon.len),
            .pop_clip => whirlpool_skia_pop_clip(self.native),
        };
    }

    pub fn end(self: *Renderer) !Frame {
        var row_bytes: usize = 0;
        const pixels = whirlpool_skia_end(self.native, &row_bytes) orelse return error.SkiaEndFailed;
        return .{
            .pixels = pixels,
            .byte_len = try std.math.mul(usize, row_bytes, self.height),
            .width = self.width,
            .height = self.height,
            .row_bytes = row_bytes,
        };
    }
};

/// Ganesh renderer for an externally allocated Vulkan image. It owns the Skia
/// context, but borrows the Vulkan instance/device/queue and each target.
pub const GpuRenderer = struct {
    native: *Native,

    pub fn init(context: VulkanContext) !GpuRenderer {
        return .{ .native = whirlpool_skia_create_vulkan(
            context.instance,
            context.physical_device,
            context.device,
            context.queue,
            context.queue_family,
        ) orelse return error.SkiaGpuInitFailed };
    }

    pub fn deinit(self: *GpuRenderer) void {
        whirlpool_skia_destroy(self.native);
        self.* = undefined;
    }

    pub fn textMetrics(self: *const GpuRenderer) TextMetrics {
        return .{ .native = self.native };
    }

    /// Ask to be woken when icons this renderer drew while they were loading
    /// are ready (see `IconWake`).
    pub fn setIconWake(self: *GpuRenderer, wake: IconWake) void {
        whirlpool_skia_set_icon_wake(self.native, wake.run, wake.context);
    }

    pub fn begin(self: *GpuRenderer, target: VulkanTarget, clear: [4]f32) !void {
        const result = whirlpool_skia_begin_vulkan(
            self.native,
            target.width,
            target.height,
            target.image,
            target.memory,
            target.memory_size,
            target.format,
            target.layout,
            target.queue_family,
        );
        if (result != 0) {
            std.log.err("Skia rejected Vulkan DMA-BUF target (stage {d})", .{result});
            return error.SkiaGpuBeginFailed;
        }
        whirlpool_skia_clear(self.native, clear[0], clear[1], clear[2], clear[3]);
    }

    pub fn drawList(self: *GpuRenderer, list: DrawList) void {
        for (list.ops) |op| switch (op) {
            .rect => |rect| drawRectNative(self.native, rect.rect, rect.radius, rect.color, rect.center),
            .polygon => |item| drawPolygonOp(self.native, item),
            .text => |item| drawTextNative(self.native, item),
            .icon => |item| whirlpool_skia_draw_icon(self.native, item.source.ptr, item.source.len, item.rect.x, item.rect.y, item.rect.width, item.rect.height, item.opacity),
            .push_clip => |rect| whirlpool_skia_push_clip(self.native, rect.x, rect.y, rect.width, rect.height),
            .push_clip_polygon => |polygon| whirlpool_skia_push_clip_polygon(self.native, @ptrCast(&polygon.points[0]), polygon.len),
            .pop_clip => whirlpool_skia_pop_clip(self.native),
        };
    }

    pub fn end(self: *GpuRenderer, final_layout: u32, final_queue_family: u32) !void {
        if (whirlpool_skia_end_vulkan(self.native, final_layout, final_queue_family) != 0)
            return error.SkiaGpuSubmitFailed;
    }
};

pub const VulkanContext = struct {
    instance: *anyopaque,
    physical_device: *anyopaque,
    device: *anyopaque,
    queue: *anyopaque,
    queue_family: u32,
};

pub const VulkanTarget = struct {
    image: *anyopaque,
    memory: *anyopaque,
    memory_size: u64,
    width: u32,
    height: u32,
    format: u32,
    layout: u32,
    queue_family: u32,
};

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };
pub const max_polygon_points = 16;
pub const Point = extern struct { x: f32, y: f32 };
pub const Polygon = struct {
    points: [max_polygon_points]Point = [_]Point{.{ .x = 0, .y = 0 }} ** max_polygon_points,
    len: u8 = 0,
};

fn drawPolygonNative(native: *Native, polygon: Polygon, color: Color) void {
    if (polygon.len < 3 or polygon.len > max_polygon_points) return;
    whirlpool_skia_draw_polygon(native, @ptrCast(&polygon.points[0]), polygon.len, color.r, color.g, color.b, color.a);
}

fn drawPolygonOp(native: *Native, item: PolygonOp) void {
    const gradient = item.gradient orelse return drawPolygonNative(native, item.points, item.color);
    if (item.points.len < 3 or item.points.len > max_polygon_points) return;
    whirlpool_skia_draw_polygon_gradient(native, @ptrCast(&item.points.points[0]), item.points.len, gradient.stops.ptr, gradient.stops.len, gradient.left, gradient.bottom, gradient.opacity);
}

/// A polygon's linear gradient. `stops` are encoded as the UI's
/// `properties.Gradient` (little-endian f32s: slant, then x, r, g, b, a per
/// stop) and borrowed from the scene; `left` and `bottom` place the stops'
/// x = 0 on the canvas, and `opacity` scales every stop's alpha.
pub const LinearGradient = struct {
    stops: []const u8,
    left: f32,
    bottom: f32,
    opacity: f32 = 1,
};

pub const PolygonOp = struct {
    points: Polygon,
    color: Color,
    /// Drawn instead of `color` when present.
    gradient: ?LinearGradient = null,
};

/// The UI module intentionally does not import this type. A host lowers its
/// retained node snapshots into this small scalar draw contract instead.
pub const DrawList = struct {
    ops: []const DrawOp,

    /// A rectangle holding everything the list draws on a `width` x `height`
    /// target (null when it draws nothing), whole pixels, so a compositor can
    /// be told only that much changed. Generous rather than exact: text has
    /// no measured width here, so it spans the target's width, from well
    /// above its baseline to below it; antialiasing gets a pixel each side.
    pub fn bounds(self: DrawList, width: f32, height: f32) ?Rect {
        var left: f32 = std.math.inf(f32);
        var top: f32 = std.math.inf(f32);
        var right: f32 = -std.math.inf(f32);
        var bottom: f32 = -std.math.inf(f32);
        const Include = struct {
            fn rect(l: *f32, t: *f32, r: *f32, b: *f32, x: f32, y: f32, w: f32, h: f32) void {
                l.* = @min(l.*, x);
                t.* = @min(t.*, y);
                r.* = @max(r.*, x + w);
                b.* = @max(b.*, y + h);
            }
        };
        for (self.ops) |op| switch (op) {
            .push_clip, .push_clip_polygon, .pop_clip => {},
            .rect => |item| Include.rect(&left, &top, &right, &bottom, item.rect.x, item.rect.y, item.rect.width, item.rect.height),
            .icon => |item| Include.rect(&left, &top, &right, &bottom, item.rect.x, item.rect.y, item.rect.width, item.rect.height),
            .polygon => |item| for (item.points.points[0..item.points.len]) |point|
                Include.rect(&left, &top, &right, &bottom, point.x, point.y, 0, 0),
            .text => |item| {
                const above = switch (item.vertical) {
                    .baseline => item.size * 1.25,
                    else => item.size * 2,
                };
                Include.rect(&left, &top, &right, &bottom, 0, item.baseline - above, width, above + item.size * 2);
            },
        };
        if (left > right or top > bottom) return null;
        const x0 = @max(0, @floor(left) - 1);
        const y0 = @max(0, @floor(top) - 1);
        const x1 = @min(width, @ceil(right) + 1);
        const y1 = @min(height, @ceil(bottom) + 1);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }
};

test "a draw list's bounds hold what it draws, and text spans the width" {
    var triangle = Polygon{ .len = 3 };
    triangle.points[0] = .{ .x = 10, .y = 90 };
    triangle.points[1] = .{ .x = 20, .y = 80.5 };
    triangle.points[2] = .{ .x = 30, .y = 95 };
    const shapes = [_]DrawOp{
        .{ .rect = .{ .rect = .{ .x = 40, .y = 70, .width = 10, .height = 5 }, .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 } } },
        .{ .polygon = .{ .points = triangle, .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 } } },
    };
    const box = (DrawList{ .ops = &shapes }).bounds(200, 100).?;
    try std.testing.expectEqual(Rect{ .x = 9, .y = 69, .width = 42, .height = 27 }, box);
    const words = [_]DrawOp{.{ .text = .{ .text = "hi", .x = 50, .baseline = 60, .size = 10, .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 } } }};
    const line = (DrawList{ .ops = &words }).bounds(200, 100).?;
    try std.testing.expectEqual(@as(f32, 0), line.x);
    try std.testing.expectEqual(@as(f32, 200), line.width);
    try std.testing.expect(line.y <= 47 and line.y + line.height >= 64);
    try std.testing.expect((DrawList{ .ops = &.{} }).bounds(200, 100) == null);
}

pub const DrawOp = union(enum) {
    push_clip: Rect,
    /// Clip to a polygon until the matching `pop_clip`.
    push_clip_polygon: Polygon,
    pop_clip,
    rect: struct {
        rect: Rect,
        radius: f32 = 0,
        color: Color,
        /// With a centre colour, a radial gradient from it out to `color` at
        /// the corners, stretched to the rect.
        center: ?Color = null,
    },
    polygon: PolygonOp,
    text: struct {
        text: []const u8,
        /// Font family name; empty for the renderer's default.
        family: []const u8 = "",
        x: f32,
        baseline: f32,
        size: f32,
        color: Color,
        anchor: TextAnchor = .start,
        vertical: TextVertical = .baseline,
    },
    icon: struct {
        source: []const u8,
        rect: Rect,
        opacity: f32,
    },
};

test "Skia binding keeps protocol ownership outside the C++ membrane" {
    try std.testing.expect(@sizeOf(Renderer) > 0);
    try std.testing.expect(@sizeOf(Rect) == @sizeOf(f32) * 4);
    try std.testing.expect(@sizeOf(Point) == @sizeOf(f32) * 2);
    try std.testing.expect(@sizeOf(DrawList) > 0);
}

test "CPU renderer resolves a system font and rasterizes text" {
    var renderer = try Renderer.init(true);
    defer renderer.deinit();
    try renderer.begin(160, 40, .{ 0, 0, 0, 0 });
    renderer.drawText("Whirlpool", 4, 28, 20, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    const frame = try renderer.end();
    const pixels = frame.pixels[0 .. frame.row_bytes * frame.height];
    var painted = false;
    for (pixels) |value| if (value != 0) {
        painted = true;
        break;
    };
    try std.testing.expect(painted);
}

test "CPU renderer rasterizes a filled polygon" {
    var renderer = try Renderer.init(true);
    defer renderer.deinit();
    try renderer.begin(32, 32, .{ 0, 0, 0, 0 });
    var polygon = Polygon{ .len = 3 };
    polygon.points[0] = .{ .x = 4, .y = 28 };
    polygon.points[1] = .{ .x = 16, .y = 4 };
    polygon.points[2] = .{ .x = 28, .y = 28 };
    renderer.drawPolygon(polygon, .{ .r = 1, .g = 0.5, .b = 0, .a = 1 });
    const frame = try renderer.end();
    const pixels = frame.pixels[0 .. frame.row_bytes * frame.height];
    var painted = false;
    for (pixels) |value| if (value != 0) {
        painted = true;
        break;
    };
    try std.testing.expect(painted);
}

test "CPU renderer fills a rect with a radial gradient, its centre colour in the middle" {
    var renderer = try Renderer.init(true);
    defer renderer.deinit();
    try renderer.begin(40, 20, .{ 0, 0, 0, 0 });
    drawRectNative(renderer.native, .{ .x = 0, .y = 0, .width = 40, .height = 20 }, 4, .{ .r = 0, .g = 0, .b = 1, .a = 1 }, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    const frame = try renderer.end();
    // BGRA: the middle is red, a corner region blue.
    const middle = frame.pixels[10 * frame.row_bytes + 20 * 4 ..][0..4];
    const corner = frame.pixels[3 * frame.row_bytes + 3 * 4 ..][0..4];
    try std.testing.expect(middle[2] > 200 and middle[0] < 60);
    try std.testing.expect(corner[0] > corner[2]);
}

test "CPU renderer decodes and rasterizes a PNG icon" {
    var renderer = try Renderer.init(true);
    defer renderer.deinit();
    try renderer.begin(32, 32, .{ 0, 0, 0, 0 });
    renderer.drawIcon("src/graphics/skia/testdata/icon.png", .{ .x = 4, .y = 4, .width = 24, .height = 24 }, 1);
    _ = try renderer.end();
    // The first draw only asks for the icon; it shows once loaded.
    _ = renderer.waitForIcons();
    try renderer.begin(32, 32, .{ 0, 0, 0, 0 });
    renderer.drawIcon("src/graphics/skia/testdata/icon.png", .{ .x = 4, .y = 4, .width = 24, .height = 24 }, 1);
    const frame = try renderer.end();
    const pixels = frame.pixels[0 .. frame.row_bytes * frame.height];
    var painted = false;
    for (pixels) |value| if (value != 0) {
        painted = true;
        break;
    };
    try std.testing.expect(painted);
}

test "CPU renderer decodes and rasterizes an SVG icon" {
    var renderer = try Renderer.init(true);
    defer renderer.deinit();
    try renderer.begin(32, 32, .{ 0, 0, 0, 0 });
    renderer.drawIcon("src/graphics/skia/testdata/icon.svg", .{ .x = 4, .y = 4, .width = 24, .height = 24 }, 1);
    _ = try renderer.end();
    _ = renderer.waitForIcons();
    try renderer.begin(32, 32, .{ 0, 0, 0, 0 });
    renderer.drawIcon("src/graphics/skia/testdata/icon.svg", .{ .x = 4, .y = 4, .width = 24, .height = 24 }, 1);
    const frame = try renderer.end();
    const pixels = frame.pixels[0 .. frame.row_bytes * frame.height];
    var painted = false;
    for (pixels) |value| if (value != 0) {
        painted = true;
        break;
    };
    try std.testing.expect(painted);
}

/// Which point of a text run `x` names: its start, centre, or end.
pub const TextAnchor = enum(u8) { start, center, end };
/// What `y` names: the alphabetic baseline, or the vertical middle of capital
/// letters (so text centres in a box without the caller knowing font metrics).
pub const TextVertical = enum(u8) { baseline, middle };

fn drawTextNative(native: *Native, item: anytype) void {
    whirlpool_skia_draw_text(
        native,
        item.family.ptr,
        item.family.len,
        item.text.ptr,
        item.text.len,
        item.x,
        item.baseline,
        item.size,
        item.color.r,
        item.color.g,
        item.color.b,
        item.color.a,
        @intFromEnum(item.anchor),
        @intFromEnum(item.vertical),
    );
}

/// Little-endian f32s, as `LinearGradient.stops` holds them.
fn testGradient(comptime count: usize, values: [1 + count * 5]f32) [4 + count * 20]u8 {
    var bytes: [4 + count * 20]u8 = undefined;
    for (values, 0..) |value, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], @bitCast(value), .little);
    return bytes;
}

test "CPU renderer fills a polygon with a leaning linear gradient" {
    var renderer = try Renderer.init(true);
    defer renderer.deinit();
    try renderer.begin(60, 20, .{ 0, 0, 0, 0 });
    var square = Polygon{ .len = 4 };
    square.points[0] = .{ .x = 0, .y = 0 };
    square.points[1] = .{ .x = 60, .y = 0 };
    square.points[2] = .{ .x = 60, .y = 20 };
    square.points[3] = .{ .x = 0, .y = 20 };
    // Red at x = 10, blue at x = 30 (on the bottom row), leaning 1 px right
    // per px up.
    const stops = testGradient(2, .{ 1, 10, 1, 0, 0, 1, 30, 0, 0, 1, 1 });
    drawPolygonOp(renderer.native, .{
        .points = square,
        .color = .{ .r = 0, .g = 1, .b = 0, .a = 1 },
        .gradient = .{ .stops = &stops, .left = 0, .bottom = 20 },
    });
    const frame = try renderer.end();
    const Pixel = struct {
        fn at(pixels: [*]const u8, row_bytes: usize, x: usize, y: usize) [4]u8 {
            return pixels[y * row_bytes + x * 4 ..][0..4].*;
        }
    };
    // BGRA. Left of the first stop is its colour, right of the last the
    // last's; the flat fill is never seen.
    const left = Pixel.at(frame.pixels, frame.row_bytes, 2, 19);
    const right = Pixel.at(frame.pixels, frame.row_bytes, 50, 19);
    try std.testing.expect(left[2] > 240 and left[0] < 15 and left[1] < 15);
    try std.testing.expect(right[0] > 240 and right[2] < 15 and right[1] < 15);
    // The midpoint (x = 20) at the bottom is half and half; 10 rows up the
    // same mix is 10 px further right, and at x = 20 it is redder.
    const bottom_mid = Pixel.at(frame.pixels, frame.row_bytes, 20, 19);
    const raised_mid = Pixel.at(frame.pixels, frame.row_bytes, 30, 9);
    const raised_same_x = Pixel.at(frame.pixels, frame.row_bytes, 20, 9);
    try std.testing.expect(@abs(@as(i32, bottom_mid[2]) - @as(i32, raised_mid[2])) <= 16);
    try std.testing.expect(@abs(@as(i32, bottom_mid[0]) - @as(i32, raised_mid[0])) <= 16);
    try std.testing.expect(raised_same_x[2] > bottom_mid[2] + 60);
}
