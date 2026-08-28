const std = @import("std");

pub const lifecycle = @import("lifecycle.zig");
pub const ipc = @import("ipc.zig");
pub const persistence = @import("persistence.zig");

pub const ConfigPath = []const u8;

pub const Mode = enum {
    /// Own window management through River's window-management protocols.
    river,
    /// Run only configured portable layer-shell surfaces under the current
    /// compositor; never claim River window-management authority.
    layer_shell,
};

pub const Options = struct {
    mode: Mode = .river,
    config_path: ?ConfigPath = null,
};

pub fn parseArgs(args: []const []const u8) error{InvalidArguments}!Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "river") or std.mem.eql(u8, arg, "run")) {
            options.mode = .river;
        } else if (std.mem.eql(u8, arg, "layer-shell")) {
            options.mode = .layer_shell;
        } else if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.InvalidArguments;
            options.config_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            const path = arg["--config=".len..];
            if (path.len == 0) return error.InvalidArguments;
            options.config_path = path;
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

test "River remains the default production mode" {
    try std.testing.expectEqual(Mode.river, (Options{}).mode);
}

test "layer-shell mode never claims River window management" {
    const options = try parseArgs(&.{"layer-shell"});
    try std.testing.expectEqual(Mode.layer_shell, options.mode);
}

test "unknown or ambiguous arguments are rejected" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"wat"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"studio"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "river", "--config" }));
}

test "config path is accepted for River" {
    const options = try parseArgs(&.{ "river", "--config", "/tmp/whirlpool.lua" });
    try std.testing.expectEqual(Mode.river, options.mode);
    try std.testing.expectEqualStrings("/tmp/whirlpool.lua", options.config_path.?);
}

test {
    _ = lifecycle;
    _ = ipc;
    _ = persistence;
}
