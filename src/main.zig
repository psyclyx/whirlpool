const std = @import("std");
const runtime = @import("whirlpool-runtime");
const river_app = @import("app/river.zig");
const layer_shell_app = @import("app/layer_shell.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    _ = iterator.skip();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (iterator.next()) |arg| try args.append(allocator, arg);

    const options = runtime.parseArgs(args.items) catch {
        std.log.err("usage: whirlpool [river|layer-shell] [--config PATH]", .{});
        return error.InvalidArguments;
    };
    const environment_config = init.minimal.environ.getAlloc(allocator, "WHIRLPOOL_CONFIG") catch null;
    defer if (environment_config) |path| allocator.free(path);
    const config_path = options.config_path orelse environment_config;

    switch (options.mode) {
        .river => try river_app.run(allocator, init.io, config_path),
        .layer_shell => try layer_shell_app.run(allocator, init.io, config_path),
    }
}
