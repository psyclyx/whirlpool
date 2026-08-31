//! Bounded, presentation-neutral projection of a layout provider's model.
//!
//! Providers may expose the structure they actually arrange without teaching
//! the shell about columns, strips, workspaces, or any other layout policy.

const std = @import("std");
const wm = @import("whirlpool-wm");

pub const max_label_bytes: usize = 24;

pub const Kind = enum { group_open, group_close, window, insertion };

pub const Label = struct {
    bytes: [max_label_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn init(value: []const u8) !Label {
        if (value.len > max_label_bytes) return error.LayoutProjectionLabelTooLong;
        var result: Label = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Token = struct {
    kind: Kind,
    label: Label = .{},
    window: ?wm.WindowId = null,
    focused: bool = false,
    selected: bool = false,
    mark: Label = .{},
};

pub const Projection = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList(Token) = .empty,

    pub fn init(allocator: std.mem.Allocator) Projection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Projection) void {
        self.tokens.deinit(self.allocator);
        self.* = undefined;
    }
};

test "projection labels are bounded inline values" {
    const label = try Label.init("vertical");
    try std.testing.expectEqualStrings("vertical", label.slice());
    try std.testing.expectError(error.LayoutProjectionLabelTooLong, Label.init("0123456789012345678901234"));
}
