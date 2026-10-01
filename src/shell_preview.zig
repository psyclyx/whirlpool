//! Render the example bar to PPM images for visual review.
//!
//! `zig build shell-preview -- <output-dir>` writes one image per scenario at
//! 1x; `-- <output-dir> --live` renders this machine's real measurements.
//! Scale them up for inspection, e.g.
//! `magick busy.ppm -filter point -resize 400% busy.png`.

const std = @import("std");
const graphics = @import("whirlpool-graphics");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const status = @import("whirlpool-app-status");

const Value = host.values.Value;
const Builder = host.values.Builder;
const width = 2400;
const height = 38;
const icon = "/run/current-system/sw/share/icons/hicolor/96x96/apps/corectrl.svg";
/// The frame clock the scenarios are drawn at.
const now_ms: f64 = 60_000;

const Scenario = struct {
    name: []const u8,
    monitor_focused: bool = true,
    battery: bool = true,
    muted: bool = false,
    swap: bool = true,
    /// Idle, then a gigabit-class burst, with a stepped CPU trace: makes the
    /// plots' geometry (shear, clipping, scale) easy to judge.
    spiky: bool = false,
};

const scenarios = [_]Scenario{
    .{ .name = "busy" },
    .{ .name = "unfocused-monitor", .monitor_focused = false },
    .{ .name = "muted-no-battery", .muted = true, .battery = false, .swap = false },
    .{ .name = "spiky", .spiky = true },
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const directory = args.next() orelse return error.MissingOutputDirectory;
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    if (args.next()) |flag| if (std.mem.eql(u8, flag, "--live")) return renderLive(allocator, init.io, script.modules.source_tree_path, directory);

    for (scenarios) |scenario| {
        var shell = try host.surface_composition.Composition.initModule(allocator, script.modules.source_tree_path, "lib.bar", "{}");
        defer shell.deinit();
        var renderer = try graphics.skia.Renderer.init(true);
        defer renderer.deinit();
        shell.setTextMetrics(renderer.textMetrics());
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try populate(&shell, arena.allocator(), scenario);
        try writeFrame(allocator, init.io, &shell, &renderer, directory, scenario.name);
    }
}

/// Render the bar from this machine's real measurement sources.
fn renderLive(allocator: std.mem.Allocator, io: std.Io, module_path: []const u8, directory: []const u8) !void {
    const origin = std.Io.Clock.awake.now(io);
    const specs = [_]status.Spec{
        .{ .name = "cpu", .kind = .cpu, .every_ms = 500, .keep_ms = 16_000 },
        .{ .name = "network", .kind = .network, .every_ms = 500, .keep_ms = 16_000 },
        .{ .name = "disks", .kind = .disks, .every_ms = 1000, .keep_ms = 8_000 },
        .{ .name = "memory", .kind = .memory, .every_ms = 2000, .keep_ms = 0 },
        .{ .name = "audio", .kind = .audio, .every_ms = 500, .keep_ms = 0 },
        .{ .name = "battery", .kind = .battery, .every_ms = 10_000, .keep_ms = 0 },
    };
    const service = try status.Service.init(allocator, io, origin, &specs);
    defer service.deinit();
    try std.Io.sleep(io, .fromSeconds(6), .awake);

    var shell = try host.surface_composition.Composition.initModule(allocator, module_path, "lib.bar", "{}");
    defer shell.deinit();
    var renderer = try graphics.skia.Renderer.init(true);
    defer renderer.deinit();
    shell.setTextMetrics(renderer.textMetrics());
    for (0..service.sourceCount()) |index| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const encoded = try service.encode(Value, arena.allocator(), index);
        try shell.update(.{ .service = service.sourceName(index), .values = &.{encoded.value} });
    }
    const elapsed = origin.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    try frame(&shell, @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms);
    try writeFrame(allocator, io, &shell, &renderer, directory, "live");
}

fn frame(shell: *host.surface_composition.Composition, at: f64) !void {
    const b = Builder{ .arena = std.heap.page_allocator };
    try shell.update(.{ .service = "frame", .values = &.{b.object(.{.{ "now", at }})} });
}

fn writeFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell: *host.surface_composition.Composition,
    renderer: *graphics.skia.Renderer,
    directory: []const u8,
    name: []const u8,
) !void {
    var lowered = try shell.lower(.{ .width = width, .height = height });
    defer lowered.deinit();
    try renderer.begin(width, height, .{ 0, 0, 0, 1 });
    renderer.drawList(lowered.drawList());
    try writePpm(allocator, io, directory, name, try renderer.end());
}

fn writePpm(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8, pixels: graphics.skia.Frame) !void {
    var rgb = try allocator.alloc(u8, pixels.width * pixels.height * 3);
    defer allocator.free(rgb);
    for (0..pixels.height) |y| for (0..pixels.width) |x| {
        const source = y * pixels.row_bytes + x * 4; // BGRA
        const target = (y * pixels.width + x) * 3;
        rgb[target] = pixels.pixels[source + 2];
        rgb[target + 1] = pixels.pixels[source + 1];
        rgb[target + 2] = pixels.pixels[source];
    };
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.ppm", .{ directory, name });
    defer allocator.free(path);
    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ pixels.width, pixels.height });
    defer allocator.free(header);
    const file = try allocator.alloc(u8, header.len + rgb.len);
    defer allocator.free(file);
    @memcpy(file[0..header.len], header);
    @memcpy(file[header.len..], rgb);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file });
}

/// Feed one scenario's desktop and measurements, as a host would.
pub fn populate(shell: *host.surface_composition.Composition, arena: std.mem.Allocator, scenario: Scenario) !void {
    const b = Builder{ .arena = arena };
    try shell.update(.{ .service = "desktop", .values = &.{desktop(b, scenario.monitor_focused)} });

    const count = 32;
    const every = 500.0;
    const t = host.values.times(arena, now_ms - every, every, count);
    var busy: [count]f64 = undefined;
    var rx: [count]f64 = undefined;
    var tx: [count]f64 = undefined;
    for (0..count) |index| {
        const step: f64 = @floatFromInt(index);
        busy[index] = 2.0 + 10.0 * @abs(@sin(step * 0.4));
        rx[index] = 300e3 + 900e3 * @abs(@sin(step * 0.35));
        tx[index] = 40e3 + 160e3 * @abs(@cos(step * 0.5));
        if (scenario.spiky) {
            busy[index] = if (index < 14) 0.3 else if (index < 20) 9.0 else if (index < 26) 1.5 else 20.0;
            rx[index] = if (index < 18) 20e3 else 175e6 * @exp(-(step - 18) / 6);
            tx[index] = if (index < 18) 5e3 else 4e6 * @exp(-(step - 18) / 5);
        }
    }
    var cores: [32]f64 = undefined;
    for (&cores, 0..) |*core, index| core.* = @max(0.0, 100.0 - @as(f64, @floatFromInt(index)) * 9.0);
    try shell.update(.{ .service = "cpu", .values = &.{b.object(.{
        .{ "t", b.numbers(t) },
        .{ "busy", b.numbers(&busy) },
        .{ "percent", b.numbers(&busy) },
        .{ "count", 32 },
        .{ "cores", b.numbers(&cores) },
    })} });
    try shell.update(.{ .service = "network", .values = &.{b.object(.{
        .{ "t", b.numbers(t) },
        .{ "rx", b.numbers(host.values.counter(arena, &rx, every)) },
        .{ "tx", b.numbers(host.values.counter(arena, &tx, every)) },
        .{ "interface", "eth0" },
    })} });
    try shell.update(.{ .service = "audio", .values = &.{b.object(.{
        .{ "t", b.numbers(&.{now_ms}) },
        .{ "percent", b.numbers(&.{63}) },
        .{ "muted", b.numbers(&.{if (scenario.muted) 1 else 0}) },
    })} });
    const gib: f64 = 1024 * 1024 * 1024;
    try shell.update(.{ .service = "memory", .values = &.{b.object(.{
        .{ "t", b.numbers(&.{now_ms}) },
        .{ "total", b.numbers(&.{64 * gib}) },
        .{ "used", b.numbers(&.{21.3 * gib}) },
        .{ "cache", b.numbers(&.{14 * gib}) },
        .{ "arc", b.numbers(&.{6 * gib}) },
        .{ "free", b.numbers(&.{20 * gib}) },
        .{ "swap_total", b.numbers(&.{if (scenario.swap) 8 * gib else 0}) },
        .{ "swap_used", b.numbers(&.{if (scenario.swap) 1.2 * gib else 0}) },
        .{ "zswap_stored", b.numbers(&.{if (scenario.swap) 3 * gib else 0}) },
        .{ "zswap_compressed", b.numbers(&.{if (scenario.swap) gib else 0}) },
    })} });
    const disk_t = host.values.times(arena, now_ms - 200, 1000, 6);
    const filesystems = [_]struct { []const u8, f64, f64, f64, f64 }{
        .{ "rpool", 1660, 1101, 4.2e6, 90e3 },
        .{ "scratchpool", 450, 24, 0, 0 },
        .{ "tank", 7373, 4198, 120e6, 3.4e6 },
        .{ "bulkpool", 21000, 12000, 0, 0 },
    };
    var disks: [filesystems.len]Value = undefined;
    for (filesystems, &disks) |entry, *disk| {
        const reads = [_]f64{entry[3]} ** 6;
        const writes = [_]f64{entry[4]} ** 6;
        disk.* = b.object(.{
            .{ "label", entry[0] },
            .{ "total", entry[1] * gib },
            .{ "used", entry[2] * gib },
            .{ "avail", (entry[1] - entry[2]) * gib },
            .{ "read", b.numbers(host.values.counter(arena, &reads, 1000)) },
            .{ "write", b.numbers(host.values.counter(arena, &writes, 1000)) },
        });
    }
    try shell.update(.{ .service = "disks", .values = &.{b.object(.{
        .{ "t", b.numbers(disk_t) },
        .{ "disks", b.array(&disks) },
    })} });
    try shell.update(.{ .service = "battery", .values = &.{b.object(.{
        .{ "t", b.numbers(&.{now_ms}) },
        .{ "present", b.numbers(&.{if (scenario.battery) 1 else 0}) },
        .{ "percent", b.numbers(&.{87}) },
        .{ "charging", b.numbers(&.{0}) },
        .{ "on_ac", b.numbers(&.{1}) },
    })} });
    // Two frames: the first starts the clocks, the second lets readouts and
    // the network scale settle.
    try frame(shell, now_ms);
    try frame(shell, now_ms + 1500);
}

fn desktop(b: Builder, focused: bool) Value {
    const occupied = [_]bool{ true, true, false, true, false, false, false, false, false };
    var tags: [9]Value = undefined;
    for (&tags, occupied, 0..) |*tag, busy, index| tag.* = b.object(.{ .{ "occupied", busy }, .{ "active", index == 1 } });
    const items = [_]Value{
        marker(b, "group-open", "h", false),
        window(b, 11, "foot", "nvim status.lua", true),
        window(b, 12, "firefox", "Whirlpool documentation — a very long page title indeed", false),
        marker(b, "insertion", "", false),
        window(b, 13, "", "", false),
        marker(b, "group-close", "", false),
    };
    return b.object(.{
        .{ "tag", 2 },
        .{ "focused", focused },
        .{ "tags", b.array(&tags) },
        .{ "items", b.array(&items) },
    });
}

pub fn window(b: Builder, id: u32, app_id: []const u8, title: []const u8, focused: bool) Value {
    var id_text: [16]u8 = undefined;
    const id_string = std.fmt.bufPrint(&id_text, "{d}", .{id}) catch unreachable;
    return b.object(.{
        .{ "kind", "window" },
        .{ "label", "" },
        .{ "detail", "" },
        .{ "focused", focused },
        .{ "overlay", false },
        .{ "window", id },
        .{ "app_id", app_id },
        .{ "title", title },
        .{ "icon", icon },
        .{ "action", "focus-window" },
        .{ "args", b.array(&.{b.from(b.arena.dupe(u8, id_string) catch unreachable)}) },
    });
}

pub fn marker(b: Builder, kind: []const u8, label: []const u8, focused: bool) Value {
    return b.object(.{
        .{ "kind", kind },
        .{ "label", label },
        .{ "detail", "" },
        .{ "focused", focused },
        .{ "overlay", true },
        .{ "window", @as(Value, .nil) },
        .{ "app_id", "" },
        .{ "title", "" },
        .{ "icon", "" },
        .{ "action", "" },
        .{ "args", b.array(&.{}) },
    });
}
