//! Bounded display items supplied by a retained Lua controller.
//!
//! The host treats style and action names as opaque strings. A concrete window
//! may be associated solely as a metadata source or flat action subject.

const std = @import("std");
const wm = @import("whirlpool-wm");

pub const max_text_bytes: usize = 64;
pub const max_action_args: usize = 4;

pub const Label = struct {
    bytes: [max_text_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn init(value: []const u8) !Label {
        if (value.len > max_text_bytes) return error.LayoutProjectionTextTooLong;
        var result: Label = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Item = struct {
    style: Label = .{},
    text: Label = .{},
    detail: Label = .{},
    window: ?wm.WindowId = null,
    focused: bool = false,
    width: u32 = 1,
    action: Label = .{},
    args: [max_action_args]Label = [_]Label{.{}} ** max_action_args,
    arg_count: u8 = 0,
};

pub const Projection = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,

    pub fn init(allocator: std.mem.Allocator) Projection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Projection) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

test "projection text is bounded inline" {
    const text = try Label.init("( horizontal");
    try std.testing.expectEqualStrings("( horizontal", text.slice());
    try std.testing.expectError(error.LayoutProjectionTextTooLong, Label.init("01234567890123456789012345678901234567890123456789012345678901234"));
}
