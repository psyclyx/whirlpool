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
extern fn whirlpool_skia_draw_polygon(renderer: *Native, points: [*]const f32, point_count: usize, r: f32, g: f32, b: f32, a: f32) void;
extern fn whirlpool_skia_draw_text(renderer: *Native, text: [*]const u8, length: usize, x: f32, y: f32, size: f32, r: f32, g: f32, b: f32, a: f32, anchor: c_int, middle: c_int) void;
extern fn whirlpool_skia_draw_icon(renderer: *Native, source: [*]const u8, length: usize, x: f32, y: f32, width: f32, height: f32, opacity: f32) void;
extern fn whirlpool_skia_push_clip(renderer: *Native, x: f32, y: f32, width: f32, height: f32) void;
extern fn whirlpool_skia_push_clip_polygon(renderer: *Native, points: [*]const f32, point_count: usize) void;
extern fn whirlpool_skia_pop_clip(renderer: *Native) void;
extern fn whirlpool_skia_end(renderer: *Native, row_bytes: *usize) ?[*]const u8;
extern fn whirlpool_skia_begin_vulkan(renderer: *Native, width: u32, height: u32, image: *anyopaque, memory: *anyopaque, memory_size: u64, format: u32, layout: u32, queue_family: u32) c_int;
extern fn whirlpool_skia_end_vulkan(renderer: *Native, final_layout: u32, final_queue_family: u32) c_int;
extern fn whirlpool_skia_measure_text(renderer: *Native, text: [*]const u8, length: usize, size: f32) f32;
extern fn whirlpool_skia_fit_text(renderer: *Native, text: [*]const u8, length: usize, size: f32, max_width: f32) usize;

/// Widths of text as a renderer draws it (its fonts, fallback included).
/// Borrowed from, and only valid as long as, that renderer.
pub const TextMetrics = struct {
    native: *Native,

    pub fn width(self: TextMetrics, text: []const u8, size: f32) f32 {
        if (text.len == 0) return 0;
        return whirlpool_skia_measure_text(self.native, text.ptr, text.len, size);
    }

    /// Bytes of the longest prefix of `text` (whole characters) at most
    /// `max_width` wide.
    pub fn fit(self: TextMetrics, text: []const u8, size: f32, max_width: f32) usize {
        if (text.len == 0) return 0;
        return @min(text.len, whirlpool_skia_fit_text(self.native, text.ptr, text.len, size, max_width));
    }
};

pub const Frame = struct {
    pixels: [*]const u8,
    byte_len: usize,
    width: u32,
    height: u32,
    row_bytes: usize,
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
        whirlpool_skia_draw_text(self.native, text.ptr, text.len, x, baseline, size, color.r, color.g, color.b, color.a, 0, 0);
    }

    pub fn drawTextItem(self: *Renderer, item: anytype) void {
        drawTextNative(self.native, item);
    }

    pub fn drawIcon(self: *Renderer, source: []const u8, rect: Rect, opacity: f32) void {
        whirlpool_skia_draw_icon(self.native, source.ptr, source.len, rect.x, rect.y, rect.width, rect.height, opacity);
    }

    /// Consume renderer-neutral operations emitted by the retained UI host.
    /// The list owns neither text nor renderer resources; callers keep it
    /// alive until this function returns.
    pub fn drawList(self: *Renderer, list: DrawList) void {
        for (list.ops) |op| switch (op) {
            .rect => |rect| self.drawRect(rect.rect, rect.radius, rect.color),
            .polygon => |item| self.drawPolygon(item.points, item.color),
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
            .rect => |rect| whirlpool_skia_draw_rect(self.native, rect.rect.x, rect.rect.y, rect.rect.width, rect.rect.height, rect.radius, rect.color.r, rect.color.g, rect.color.b, rect.color.a),
            .polygon => |item| drawPolygonNative(self.native, item.points, item.color),
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

/// The UI module intentionally does not import this type. A host lowers its
/// retained node snapshots into this small scalar draw contract instead.
pub const DrawList = struct {
    ops: []const DrawOp,
};

pub const DrawOp = union(enum) {
    push_clip: Rect,
    /// Clip to a polygon until the matching `pop_clip`.
    push_clip_polygon: Polygon,
    pop_clip,
    rect: struct {
        rect: Rect,
        radius: f32 = 0,
        color: Color,
    },
    polygon: struct {
        points: Polygon,
        color: Color,
    },
    text: struct {
        text: []const u8,
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

test "CPU renderer decodes and rasterizes an SVG icon" {
    var renderer = try Renderer.init(true);
    defer renderer.deinit();
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
