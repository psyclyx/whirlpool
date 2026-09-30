const std = @import("std");
const runtime = @import("whirlpool-runtime");
const river_app = @import("whirlpool-app-river");
const layer_shell_app = @import("whirlpool-app-layer-shell");

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
    // State that should survive a restart of this process (not of the login
    // session) lives in the runtime directory, scoped to the Wayland display.
    const runtime_dir = init.minimal.environ.getAlloc(allocator, "XDG_RUNTIME_DIR") catch null;
    defer if (runtime_dir) |path| allocator.free(path);
    const display = init.minimal.environ.getAlloc(allocator, "WAYLAND_DISPLAY") catch null;
    defer if (display) |name| allocator.free(name);
    const state_override = init.minimal.environ.getAlloc(allocator, "WHIRLPOOL_STATE_PREFIX") catch null;
    defer if (state_override) |path| allocator.free(path);
    const state_prefix = if (state_override) |path|
        allocator.dupe(u8, path) catch null
    else if (runtime_dir) |directory|
        std.fmt.allocPrint(allocator, "{s}/whirlpool-{s}", .{ directory, display orelse "wayland-0" }) catch null
    else
        null;
    defer if (state_prefix) |prefix| allocator.free(prefix);

    switch (options.mode) {
        .river => try river_app.run(allocator, init.io, config_path, state_prefix),
        .layer_shell => try layer_shell_app.run(allocator, init.io, config_path),
    }
}
