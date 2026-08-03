const std = @import("std");

pub const Mode = enum {
    /// Own window management through River's window-management protocols.
    river,
    /// Own a normal preview surface and graphics context; never bind River's
    /// window-management protocols or claim its window-manager seat.
    studio,
};

pub const Options = struct {
    mode: Mode = .river,
};

pub const StartupPlan = struct {
    create_graphics_context: bool,
    connect_wayland_display: bool,
    bind_river_window_manager: bool,
};

pub fn parseArgs(args: []const []const u8) error{InvalidArguments}!Options {
    if (args.len == 0) return .{};
    if (args.len != 1) return error.InvalidArguments;

    if (std.mem.eql(u8, args[0], "river") or std.mem.eql(u8, args[0], "run")) {
        return .{ .mode = .river };
    }
    if (std.mem.eql(u8, args[0], "studio") or std.mem.eql(u8, args[0], "--studio")) {
        return .{ .mode = .studio };
    }
    return error.InvalidArguments;
}

pub fn startupPlan(options: Options) StartupPlan {
    return switch (options.mode) {
        .river => .{
            .create_graphics_context = true,
            .connect_wayland_display = true,
            .bind_river_window_manager = true,
        },
        .studio => .{
            .create_graphics_context = true,
            .connect_wayland_display = true,
            .bind_river_window_manager = false,
        },
    };
}

test "studio mode cannot acquire River window management" {
    const options = try parseArgs(&.{"studio"});
    const plan = startupPlan(options);

    try std.testing.expectEqual(Mode.studio, options.mode);
    try std.testing.expect(plan.create_graphics_context);
    try std.testing.expect(plan.connect_wayland_display);
    try std.testing.expect(!plan.bind_river_window_manager);
}

test "River remains the default production mode" {
    const plan = startupPlan(try parseArgs(&.{}));
    try std.testing.expect(plan.bind_river_window_manager);
}

test "unknown or ambiguous arguments are rejected" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"wat"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "studio", "extra" }));
}
