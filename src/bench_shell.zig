const std = @import("std");
const graphics = @import("whirlpool-graphics");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const status = @import("whirlpool-app-status");

const warmup_iterations = 20;
const measured_iterations = 200;
const viewport_width = 1200;
const viewport_height = 600;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var example_modules = try script.modules.collect(allocator, init.io, "config");
    defer example_modules.deinit();
    var shell = try host.surface_composition.Composition.init(allocator, example_modules.modules,
        \\return require("lib.bar")
    );
    defer shell.deinit();
    try populate(&shell);

    var renderer = try graphics.skia.Renderer.init(true);
    defer renderer.deinit();
    shell.setTextMetrics(renderer.textMetrics());

    var update_ns: i128 = 0;
    var lower_ns: i128 = 0;
    var draw_ns: i128 = 0;
    var operation_sum: usize = 0;
    var node_sum: usize = 0;

    for (0..warmup_iterations + measured_iterations) |index| {
        const update_start = std.Io.Clock.awake.now(init.io);
        try shell.update(.{
            .service = "frame",
            .values = &.{.{ .number = @floatFromInt(index * 16) }},
        });
        const lower_start = std.Io.Clock.awake.now(init.io);
        var frame = try shell.lower(.{ .width = viewport_width, .height = viewport_height });
        const draw_start = std.Io.Clock.awake.now(init.io);
        try renderer.begin(viewport_width, viewport_height, .{ 0, 0, 0, 0 });
        renderer.drawList(frame.drawList());
        const pixels = try renderer.end();
        const draw_end = std.Io.Clock.awake.now(init.io);

        if (index >= warmup_iterations) {
            update_ns += update_start.durationTo(lower_start).nanoseconds;
            lower_ns += lower_start.durationTo(draw_start).nanoseconds;
            draw_ns += draw_start.durationTo(draw_end).nanoseconds;
            operation_sum += frame.operationCount();
            node_sum += frame.node_count;
            std.mem.doNotOptimizeAway(pixels.pixels[pixels.byte_len - 1]);
        }
        frame.deinit();
    }

    const count: f64 = measured_iterations;
    std.debug.print(
        "shell frame: update {d:.3} ms, layout+lower {d:.3} ms, CPU draw {d:.3} ms; nodes {d}, ops {d}\n",
        .{
            @as(f64, @floatFromInt(update_ns)) / count / std.time.ns_per_ms,
            @as(f64, @floatFromInt(lower_ns)) / count / std.time.ns_per_ms,
            @as(f64, @floatFromInt(draw_ns)) / count / std.time.ns_per_ms,
            node_sum / measured_iterations,
            operation_sum / measured_iterations,
        },
    );

    var representative = try shell.lower(.{ .width = viewport_width, .height = viewport_height });
    defer representative.deinit();
    var rects: usize = 0;
    var polygons: usize = 0;
    var texts: usize = 0;
    var icons: usize = 0;
    for (representative.drawList().ops) |operation| switch (operation) {
        .rect => rects += 1,
        .polygon => polygons += 1,
        .text => texts += 1,
        .icon => icons += 1,
        .push_clip, .pop_clip => {},
    };
    std.debug.print("ops: {d} rect, {d} polygon, {d} text, {d} icon\n", .{ rects, polygons, texts, icons });
    inline for (.{ DrawMode.empty, .geometry, .text, .icon, .full }) |mode| {
        const average_ns = try measureDraw(init.io, &renderer, representative.drawList(), mode);
        std.debug.print("CPU draw {s}: {d:.3} ms\n", .{ @tagName(mode), average_ns / std.time.ns_per_ms });
    }
    try renderer.begin(viewport_width, viewport_height, .{ 0, 0, 0, 0 });
    renderer.drawList(representative.drawList());
    const pixels = try renderer.end();
    const checksum = std.hash.Wyhash.hash(0, pixels.pixels[0..pixels.byte_len]);
    std.debug.print("pixel checksum: {x}\n", .{checksum});
}

const DrawMode = enum { empty, geometry, text, icon, full };

fn measureDraw(io: std.Io, renderer: *graphics.skia.Renderer, list: graphics.skia.DrawList, comptime mode: DrawMode) !f64 {
    var total_ns: i128 = 0;
    for (0..warmup_iterations + measured_iterations) |index| {
        const start = std.Io.Clock.awake.now(io);
        try renderer.begin(viewport_width, viewport_height, .{ 0, 0, 0, 0 });
        if (mode == .full) {
            renderer.drawList(list);
        } else for (list.ops) |operation| switch (operation) {
            .rect => |rect| if (mode == .geometry) renderer.drawRect(rect.rect, rect.radius, rect.color),
            .polygon => |polygon| if (mode == .geometry) renderer.drawPolygon(polygon.points, polygon.color),
            .text => |item| if (mode == .text) renderer.drawTextItem(item),
            .icon => |item| if (mode == .icon) renderer.drawIcon(item.source, item.rect, item.opacity),
            .push_clip, .pop_clip => {},
        };
        const pixels = try renderer.end();
        const end = std.Io.Clock.awake.now(io);
        if (index >= warmup_iterations) {
            total_ns += start.durationTo(end).nanoseconds;
            std.mem.doNotOptimizeAway(pixels.pixels[pixels.byte_len - 1]);
        }
    }
    return @as(f64, @floatFromInt(total_ns)) / measured_iterations;
}

fn populate(shell: *host.surface_composition.Composition) !void {
    const first_window = [_]script.program_loader.Value{
        .{ .string = "window" }, .{ .string = "" },     .{ .string = "foot" }, .{ .string = "terminal" },
        .{ .boolean = true },    .{ .number = 148 },    .{ .string = "" },     .{ .string = "" },
        .{ .number = 0 },        .{ .boolean = false },
    };
    const second_window = [_]script.program_loader.Value{
        .{ .string = "window" }, .{ .string = "" },     .{ .string = "firefox" }, .{ .string = "browser" },
        .{ .boolean = false },   .{ .number = 148 },    .{ .string = "" },        .{ .string = "" },
        .{ .number = 152 },      .{ .boolean = false },
    };
    const windows = [_]script.program_loader.Value{
        .{ .array = &first_window },
        .{ .array = &second_window },
    };
    try shell.update(.{
        .service = "desktop",
        .values = &.{
            .{ .number = 1 },   .{ .array = &.{} }, .{ .array = &windows }, .{ .number = 0 },
            .{ .number = 300 }, .{ .number = 0 },   .{ .number = 0 },
        },
    });

    var snapshot = status.Snapshot{};
    snapshot.cpu_core_count = 32;
    snapshot.cpu_core_equivalents = 1.25;
    snapshot.cpu_cores[0] = 100;
    snapshot.cpu_cores[1] = 25;
    snapshot.cpu_sample_sequence = 1;
    snapshot.network_sample_sequence = 1;
    for (&snapshot.cpu_history) |*sample| sample.* = 1.25;
    for (&snapshot.network_rx_history) |*sample| sample.* = 256 * 1024;
    for (&snapshot.network_tx_history) |*sample| sample.* = 128 * 1024;
    var storage: status.StatusValues(script.program_loader.Value) = .{};
    try shell.update(.{ .service = "status", .values = storage.build(&snapshot) });
}
