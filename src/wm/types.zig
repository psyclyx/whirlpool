//! Public, protocol-free values owned by the WM kernel.

const std = @import("std");
const ids = @import("ids.zig");

pub const NodeId = ids.Id(.node);
pub const ColumnId = ids.Id(.column);
pub const TagId = ids.Id(.tag);
pub const OutputId = ids.Id(.output);
pub const WindowId = ids.Id(.window);
pub const Lifecycle = enum { announced, managed, closing };
pub const Placement = enum { tiled, floating, fullscreen, scratchpad };
pub const RestoredPlacement = enum { tiled, floating };
pub const PlacementTransition = enum {
    tiled,
    floating,
    fullscreen,
    scratchpad,
    exit_fullscreen,
    toggle_scratchpad,
};
pub const Axis = enum { horizontal, vertical };
pub const ContainerMode = enum { split, tabbed };
pub const Direction = enum { left, right, up, down };
pub const OutputTransform = enum {
    normal,
    ninety,
    one_eighty,
    two_seventy,
    flipped,
    flipped_ninety,
    flipped_one_eighty,
    flipped_two_seventy,
};
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
/// The four protocol-independent edges that may participate in a floating
/// resize. The bit layout matches the common compositor edge convention:
/// top=1, bottom=2, left=4, right=8.
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
pub const Camera = struct { current: f32 = 0, target: f32 = 0 };
pub const OutputConfig = struct {
    enabled: bool = true,
    scale: f32 = 1,
    transform: OutputTransform = .normal,
    mode: ?Size = null,
};
pub const Child = struct { id: NodeId, weight: f32 = 1 };
pub const Node = struct {
    id: NodeId = NodeId.invalid,
    column: ColumnId = ColumnId.invalid,
    parent: ?NodeId = null,
    window: ?WindowId = null,
    mode: ?ContainerMode = null,
    axis: Axis = .vertical,
    active_child: usize = 0,
    children: std.ArrayList(Child) = .empty,
    pub fn isLeaf(self: *const Node) bool {
        return self.window != null and self.mode == null;
    }
    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
    }
    pub fn clone(self: Node, allocator: std.mem.Allocator) !Node {
        var copy = self;
        copy.children = .empty;
        try copy.children.appendSlice(allocator, self.children.items);
        return copy;
    }
};
pub const Column = struct {
    id: ColumnId = ColumnId.invalid,
    tag: TagId = TagId.invalid,
    width: f32 = 0.5,
    root: ?NodeId = null,
    pub fn clone(self: Column, _: std.mem.Allocator) !Column {
        return self;
    }
};
pub const Mark = struct {
    name: []u8,

    pub fn deinit(self: *Mark, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }

    pub fn clone(self: Mark, allocator: std.mem.Allocator) !Mark {
        return .{ .name = try allocator.dupe(u8, self.name) };
    }
};
pub const Tag = struct {
    id: TagId = TagId.invalid,
    name: []u8 = &.{},
    columns: std.ArrayList(ColumnId) = .empty,
    focused: ?NodeId = null,
    camera: Camera = .{},
    pub fn deinit(self: *Tag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.columns.deinit(allocator);
    }
    pub fn clone(self: Tag, allocator: std.mem.Allocator) !Tag {
        var copy = self;
        copy.name = try allocator.dupe(u8, self.name);
        copy.columns = .empty;
        errdefer allocator.free(copy.name);
        try copy.columns.appendSlice(allocator, self.columns.items);
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
pub const Window = struct {
    id: WindowId = WindowId.invalid,
    tag: TagId = TagId.invalid,
    output: ?OutputId = null,
    lifecycle: Lifecycle = .announced,
    placement: Placement = .tiled,
    restore_placement: RestoredPlacement = .tiled,
    floating_geometry: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    size_hints: SizeHints = .{},
    actual_size: ?Size = null,
    proposed_size: ?Size = null,
    focus_serial: u64 = 0,
    marks: std.ArrayList(Mark) = .empty,
    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        for (self.marks.items) |*mark| mark.deinit(allocator);
        self.marks.deinit(allocator);
    }
    pub fn clone(self: Window, allocator: std.mem.Allocator) !Window {
        var copy = self;
        copy.marks = .empty;
        errdefer copy.deinit(allocator);
        try copy.marks.ensureTotalCapacity(allocator, self.marks.items.len);
        for (self.marks.items) |mark| copy.marks.appendAssumeCapacity(try mark.clone(allocator));
        return copy;
    }
};
pub const WindowSpec = struct {
    tag: TagId,
    output: ?OutputId = null,
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
pub const ColumnSpec = struct { width: f32 = 0.5 };
pub fn isFinitePositive(value: f32) bool {
    return std.math.isFinite(value) and value > 0;
}
