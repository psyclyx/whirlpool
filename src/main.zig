const std = @import("std");
const runtime = @import("whirlpool-runtime");
const studio = @import("whirlpool-studio");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    _ = iterator.skip();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (iterator.next()) |arg| try args.append(allocator, arg);

    const options = runtime.parseArgs(args.items) catch {
        std.log.err("usage: whirlpool [river|studio]", .{});
        return error.InvalidArguments;
    };
    const plan = runtime.startupPlan(options);

    switch (options.mode) {
        .river => std.log.info("River host selected (graphics={}, river={})", .{
            plan.create_graphics_context,
            plan.bind_river_window_manager,
        }),
        .studio => {
            std.debug.assert(!plan.bind_river_window_manager);
            try studio.run();
        },
    }
}
