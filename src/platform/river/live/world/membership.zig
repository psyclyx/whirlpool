//! Which tag each window was on, remembered across a window-manager restart.
//!
//! River keeps the windows and gives each a stable identifier, but not the
//! arrangement, which is ours. This is the part Zig owns (tag membership and
//! focus); the layout's own structure is persisted by the layout script. The
//! format is deliberately plain text:
//!
//!     whirlpool-membership 1
//!     window <identifier> <tag ordinal>
//!     focus <identifier>

const std = @import("std");

pub const header = "whirlpool-membership 1";

pub const Membership = struct {
    allocator: std.mem.Allocator,
    tags: std.StringHashMapUnmanaged(u8) = .empty,
    focus: ?[]u8 = null,

    pub fn deinit(self: *Membership) void {
        var keys = self.tags.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.tags.deinit(self.allocator);
        if (self.focus) |value| self.allocator.free(value);
        self.* = undefined;
    }

    /// The tag ordinal (1-based) a window was on, if it was recorded.
    pub fn tagFor(self: *const Membership, identifier: []const u8) ?u8 {
        return self.tags.get(identifier);
    }

    pub fn isFocus(self: *const Membership, identifier: []const u8) bool {
        return if (self.focus) |value| std.mem.eql(u8, value, identifier) else false;
    }

    /// Best effort: unrecognised or malformed lines are skipped; a missing or
    /// wrong header yields nothing.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !?Membership {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const first = lines.next() orelse return null;
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), header)) return null;
        var result = Membership{ .allocator = allocator };
        errdefer result.deinit();
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const kind = fields.next() orelse continue;
            const identifier = fields.next() orelse continue;
            if (identifier.len == 0 or identifier.len > 32) continue;
            if (std.mem.eql(u8, kind, "window")) {
                const ordinal = std.fmt.parseUnsigned(u8, fields.next() orelse continue, 10) catch continue;
                if (ordinal == 0) continue;
                const owned = try allocator.dupe(u8, identifier);
                errdefer allocator.free(owned);
                const entry = try result.tags.getOrPut(allocator, owned);
                if (entry.found_existing) allocator.free(owned);
                entry.value_ptr.* = ordinal;
            } else if (std.mem.eql(u8, kind, "focus")) {
                if (result.focus) |old| allocator.free(old);
                result.focus = try allocator.dupe(u8, identifier);
            }
        }
        return result;
    }
};

pub const Entry = struct { identifier: []const u8, tag_ordinal: usize };

/// Render the membership file for the given windows.
pub fn format(allocator: std.mem.Allocator, entries: []const Entry, focus: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, header);
    try out.append(allocator, '\n');
    for (entries) |entry| {
        try out.print(allocator, "window {s} {d}\n", .{ entry.identifier, entry.tag_ordinal });
    }
    if (focus) |identifier| try out.print(allocator, "focus {s}\n", .{identifier});
    return out.toOwnedSlice(allocator);
}

test "membership round-trips through its file format" {
    const text = try format(std.testing.allocator, &.{
        .{ .identifier = "abc123", .tag_ordinal = 2 },
        .{ .identifier = "def456", .tag_ordinal = 5 },
    }, "def456");
    defer std.testing.allocator.free(text);
    var membership = (try Membership.parse(std.testing.allocator, text)).?;
    defer membership.deinit();
    try std.testing.expectEqual(@as(?u8, 2), membership.tagFor("abc123"));
    try std.testing.expectEqual(@as(?u8, 5), membership.tagFor("def456"));
    try std.testing.expectEqual(@as(?u8, null), membership.tagFor("other"));
    try std.testing.expect(membership.isFocus("def456"));
    try std.testing.expect(!membership.isFocus("abc123"));
}

test "a damaged or foreign file is ignored, not fatal" {
    try std.testing.expectEqual(@as(?Membership, null), try Membership.parse(std.testing.allocator, ""));
    try std.testing.expectEqual(@as(?Membership, null), try Membership.parse(std.testing.allocator, "garbage\nwindow a 1\n"));
    var partial = (try Membership.parse(std.testing.allocator,
        \\whirlpool-membership 1
        \\window good 3
        \\window bad notanumber
        \\window zero 0
        \\window
        \\mystery line here
        \\window also-good 4
        \\
    )).?;
    defer partial.deinit();
    try std.testing.expectEqual(@as(?u8, 3), partial.tagFor("good"));
    try std.testing.expectEqual(@as(?u8, 4), partial.tagFor("also-good"));
    try std.testing.expectEqual(@as(?u8, null), partial.tagFor("bad"));
    try std.testing.expectEqual(@as(?u8, null), partial.tagFor("zero"));
}
