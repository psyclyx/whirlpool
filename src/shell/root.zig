//! Reusable desktop-shell vocabulary extracted from Shoal's useful boundary.
//!
//! This module describes surfaces and views. It deliberately owns neither a
//! Wayland connection nor a graphics context; Whirlpool is the host for both.

const std = @import("std");
const model = @import("whirlpool-model");

pub const Layer = enum { background, bottom, top, overlay };

pub const Anchors = packed struct(u4) {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

pub const SurfaceSpec = struct {
    name: []const u8,
    layer: Layer = .top,
    anchors: Anchors = .{},
    exclusive_zone: i32 = 0,
    output: ?model.OutputId = null,
};

pub fn validateSurface(spec: SurfaceSpec) error{InvalidSurface}!void {
    if (spec.name.len == 0) return error.InvalidSurface;
    if (spec.exclusive_zone < -1) return error.InvalidSurface;
}

test "surface descriptions are host-independent values" {
    const spec: SurfaceSpec = .{
        .name = "bar",
        .anchors = .{ .top = true, .left = true, .right = true },
        .exclusive_zone = 32,
        .output = @enumFromInt(7),
    };
    try validateSurface(spec);
    try std.testing.expect(spec.anchors.top);
    try std.testing.expectEqual(@as(i32, 32), spec.exclusive_zone);
}

test "invalid shell surfaces fail before reaching Wayland" {
    try std.testing.expectError(error.InvalidSurface, validateSurface(.{ .name = "" }));
    try std.testing.expectError(error.InvalidSurface, validateSurface(.{
        .name = "bad-zone",
        .exclusive_zone = -2,
    }));
}
