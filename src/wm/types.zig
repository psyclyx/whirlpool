//! Public, protocol-free resource facts owned by the WM kernel.

const std = @import("std");
const ids = @import("ids.zig");

pub const TagId = ids.TagId;
pub const OutputId = ids.OutputId;
pub const WindowId = ids.WindowId;
pub const Lifecycle = enum { announced, managed, closing };
pub const Placement = enum { unplaced, tiled, floating, fullscreen, scratchpad };
pub const RestoredPlacement = enum { tiled, floating };
pub const PlacementTransition = enum { tiled, floating, fullscreen, scratchpad, exit_fullscreen, toggle_scratchpad };
pub const OutputTransform = enum { normal, ninety, one_eighty, two_seventy, flipped, flipped_ninety, flipped_one_eighty, flipped_two_seventy };
pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { width: u32, height: u32 };
pub const SizeHints = struct {
    min: Size = .{ .width = 0, .height = 0 },
    max: Size = .{ .width = 0, .height = 0 },

    pub fn fixed(self: @This()) ?Size {
        if (self.min.width == 0 or self.min.height == 0) return null;
        if (self.min.width != self.max.width or self.min.height != self.max.height) return null;
        return self.min;
    }
};
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn right(self: Rect) i64 {
        return @as(i64, self.x) + @as(i64, self.width);
    }

    pub fn bottom(self: Rect) i64 {
        return @as(i64, self.y) + @as(i64, self.height);
    }
};
pub const ResizeEdges = packed struct(u4) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub fn fromBits(raw_bits: u32) !@This() {
        if (raw_bits == 0 or raw_bits & ~@as(u32, 0xf) != 0) return error.InvalidResizeEdges;
        const result: @This() = .{
            .top = raw_bits & 0x1 != 0,
            .bottom = raw_bits & 0x2 != 0,
            .left = raw_bits & 0x4 != 0,
            .right = raw_bits & 0x8 != 0,
        };
        if (!result.isValid()) return error.InvalidResizeEdges;
        return result;
    }

    pub fn bits(self: @This()) u32 {
        return (@as(u32, @intFromBool(self.top)) << 0) |
            (@as(u32, @intFromBool(self.bottom)) << 1) |
            (@as(u32, @intFromBool(self.left)) << 2) |
            (@as(u32, @intFromBool(self.right)) << 3);
    }

    pub fn isValid(self: @This()) bool {
        const horizontal = self.left or self.right;
        const vertical = self.top or self.bottom;
        return (horizontal or vertical) and !(self.left and self.right) and !(self.top and self.bottom);
    }
};
pub const OutputConfig = struct {
    enabled: bool = true,
    scale: f32 = 1,
    transform: OutputTransform = .normal,
    mode: ?Size = null,
};
pub const Tag = struct {
    id: TagId = TagId.invalid,
    name: []u8 = &.{},

    pub fn deinit(self: *Tag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }

    pub fn clone(self: Tag, allocator: std.mem.Allocator) !Tag {
        var copy = self;
        copy.name = try allocator.dupe(u8, self.name);
        return copy;
    }
};
pub const Output = struct {
    id: OutputId = OutputId.invalid,
    active_tag: TagId = TagId.invalid,
    previous_tag: ?TagId = null,
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    usable: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    configuration: OutputConfig = .{},

    pub fn clone(self: Output, _: std.mem.Allocator) !Output {
        return self;
    }
};
/// River's stable name for a window (up to 32 printable ASCII bytes): it
/// survives a window-manager restart, so persisted layout can be matched back
/// to the same windows.
pub const Identifier = struct {
    bytes: [32]u8 = undefined,
    len: u8 = 0,

    pub fn init(text: []const u8) Identifier {
        var result = Identifier{};
        result.len = @intCast(@min(text.len, result.bytes.len));
        @memcpy(result.bytes[0..result.len], text[0..result.len]);
        return result;
    }

    pub fn slice(self: *const Identifier) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Window = struct {
    id: WindowId = WindowId.invalid,
    tag: TagId = TagId.invalid,
    identifier: Identifier = .{},
    lifecycle: Lifecycle = .announced,
    transient: bool = false,
    placement: Placement = .tiled,
    restore_placement: RestoredPlacement = .tiled,
    floating_geometry: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    size_hints: SizeHints = .{},
    actual_size: ?Size = null,
    proposed_size: ?Size = null,

    pub fn clone(self: Window, _: std.mem.Allocator) !Window {
        return self;
    }
};
pub const WindowSpec = struct {
    tag: TagId,
    identifier: Identifier = .{},
    transient: bool = false,
    placement: Placement = .tiled,
    floating_geometry: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    size_hints: SizeHints = .{},
    actual_size: ?Size = null,
    proposed_size: ?Size = null,
};
pub const OutputSpec = struct {
    active_tag: TagId,
    bounds: Rect,
    usable: Rect,
    configuration: OutputConfig = .{},
};
pub fn isFinitePositive(value: f32) bool {
    return std.math.isFinite(value) and value > 0;
}
