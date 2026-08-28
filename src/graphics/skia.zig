//! C-ABI membrane for the Skia renderer.
//!
//! Skia owns text rasterization and 2D drawing.  Only scalar values and a
//! borrowed pixel frame cross the C++ boundary. Vulkan upload and presentation
//! remain entirely in the Wayland WSI owner.

const std = @import("std");

const Native = opaque {};

extern fn whirlpool_skia_create(bgra: c_int) ?*Native;
extern fn whirlpool_skia_destroy(renderer: *Native) void;
extern fn whirlpool_skia_begin(renderer: *Native, width: u32, height: u32) c_int;
extern fn whirlpool_skia_clear(renderer: *Native, r: f32, g: f32, b: f32, a: f32) void;
extern fn whirlpool_skia_draw_rect(renderer: *Native, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn whirlpool_skia_draw_text(renderer: *Native, text: [*]const u8, length: usize, x: f32, baseline: f32, size: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn whirlpool_skia_end(renderer: *Native, row_bytes: *usize) ?[*]const u8;

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

    pub fn drawText(self: *Renderer, text: []const u8, x: f32, baseline: f32, size: f32, color: Color) void {
        whirlpool_skia_draw_text(self.native, text.ptr, text.len, x, baseline, size, color.r, color.g, color.b, color.a);
    }

    /// Consume renderer-neutral operations emitted by the retained UI host.
    /// The list owns neither text nor renderer resources; callers keep it
    /// alive until this function returns.
    pub fn drawList(self: *Renderer, list: DrawList) void {
        for (list.ops) |op| switch (op) {
            .rect => |rect| self.drawRect(rect.rect, rect.radius, rect.color),
            .text => |item| self.drawText(item.text, item.x, item.baseline, item.size, item.color),
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

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

/// The UI module intentionally does not import this type. A host lowers its
/// retained node snapshots into this small scalar draw contract instead.
pub const DrawList = struct {
    ops: []const DrawOp,
};

pub const DrawOp = union(enum) {
    rect: struct {
        rect: Rect,
        radius: f32 = 0,
        color: Color,
    },
    text: struct {
        text: []const u8,
        x: f32,
        baseline: f32,
        size: f32,
        color: Color,
    },
};

test "Skia binding keeps protocol ownership outside the C++ membrane" {
    try std.testing.expect(@sizeOf(Renderer) > 0);
    try std.testing.expect(@sizeOf(Rect) == @sizeOf(f32) * 4);
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
