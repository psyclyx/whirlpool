const std = @import("std");
const graphics = @import("whirlpool-graphics");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");

const warmup_iterations = 20;
const measured_iterations = 200;
const viewport_width = 1200;
const viewport_height = 600;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var example_modules = try script.modules.collect(allocator, init.io, "config");
    defer example_modules.deinit();
    var shell = try host.surface_composition.Composition.initModule(allocator, example_modules.modules, "lib.bar", "{}");
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
            .values = &.{.{ .object = &.{.{ .key = "now", .value = .{ .number = 16_000 + @as(f64, @floatFromInt(index * 16)) } }} }},
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

/// A desktop with two windows and steady CPU and network history: what a
/// host feeds the bar between frames.
fn populate(shell: *host.surface_composition.Composition) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const b = host.values.Builder{ .arena = arena };
    const window = struct {
        fn make(builder: host.values.Builder, id: []const u8, app_id: []const u8, focused: bool) host.values.Value {
            return builder.object(.{
                .{ "kind", "window" }, .{ "label", "" }, .{ "detail", "" }, .{ "focused", focused },
                .{ "overlay", false }, .{ "window", 1 }, .{ "app_id", app_id }, .{ "title", "terminal" },
                .{ "icon", "" }, .{ "action", "focus-window" }, .{ "args", builder.array(&.{builder.from(id)}) },
            });
        }
    }.make;
    var tags: [9]host.values.Value = undefined;
    for (&tags, 0..) |*tag, index| tag.* = b.object(.{ .{ "occupied", index < 2 }, .{ "active", index == 0 } });
    try shell.update(.{ .service = "desktop", .values = &.{b.object(.{
        .{ "tag", 1 }, .{ "focused", true }, .{ "tags", b.array(&tags) },
        .{ "items", b.array(&.{ window(b, "1", "foot", true), window(b, "2", "firefox", false) }) },
    })} });
    const t = host.values.times(arena, 0, 500, 32);
    const busy = [_]f64{1.25} ** 32;
    var cores = [_]f64{0} ** 32;
    cores[0] = 100;
    cores[1] = 25;
    try shell.update(.{ .service = "cpu", .values = &.{b.object(.{
        .{ "t", b.numbers(t) }, .{ "busy", b.numbers(&busy) }, .{ "percent", b.numbers(&busy) },
        .{ "count", 32 }, .{ "cores", b.numbers(&cores) },
    })} });
    const rx = [_]f64{256 * 1024} ** 32;
    const tx = [_]f64{128 * 1024} ** 32;
    try shell.update(.{ .service = "network", .values = &.{b.object(.{
        .{ "t", b.numbers(t) }, .{ "rx", b.numbers(host.values.counter(arena, &rx, 500)) },
        .{ "tx", b.numbers(host.values.counter(arena, &tx, 500)) }, .{ "interface", "eth0" },
    })} });
}
