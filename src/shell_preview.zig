//! Render the example shell to PPM images for visual review.
//!
//! `zig build shell-preview -- <output-dir>` writes one image per scenario at
//! 1x. Scale them up for inspection, e.g.
//! `magick busy.ppm -filter point -resize 400% busy.png`.

const std = @import("std");
const graphics = @import("whirlpool-graphics");
const host = @import("whirlpool-host");
const script = @import("whirlpool-script");
const status = @import("whirlpool-app-status");

const Value = script.program_loader.Value;
const width = 2700;
const height = 38;
const icon = "/run/current-system/sw/share/icons/hicolor/96x96/apps/corectrl.svg";

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
    var example_modules = try script.modules.collect(allocator, init.io, "config");
    defer example_modules.deinit();
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const directory = args.next() orelse return error.MissingOutputDirectory;
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    if (args.next()) |flag| if (std.mem.eql(u8, flag, "--live")) return renderLive(allocator, init.io, directory);

    for (scenarios) |scenario| {
        var shell = try host.surface_composition.Composition.init(allocator, example_modules.modules,
            \\return require("lib.bar")
        );
        defer shell.deinit();
        try populate(&shell, scenario);
        // Advance the retained clock so scrolling plots sit mid-sample.
        try shell.update(.{ .service = "frame", .values = &.{.{ .number = 250 }} });

        var frame = try shell.lower(.{ .width = width, .height = height });
        defer frame.deinit();
        var renderer = try graphics.skia.Renderer.init(true);
        defer renderer.deinit();
        try renderer.begin(width, height, .{ 0, 0, 0, 1 });
        renderer.drawList(frame.drawList());
        const pixels = try renderer.end();
        try writePpm(allocator, init.io, directory, scenario.name, pixels);
    }
}

/// Render the bar from this machine's real status collectors.
fn renderLive(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !void {
    var example_modules = try script.modules.collect(allocator, io, "config");
    defer example_modules.deinit();
    const service = try status.Service.init(allocator, io);
    defer service.deinit();
    try std.Io.sleep(io, .fromSeconds(4), .awake);
    const latest = service.latestAfter(0) orelse return error.NoStatus;
    const snapshot = latest.value;
    std.debug.print("memory {any}\n", .{snapshot.memory});
    for (snapshot.disks[0..snapshot.disk_count]) |disk| std.debug.print("disk {s} total {d} used {d} avail {d} r {d:.0} w {d:.0}\n", .{ disk.labelSlice(), disk.total, disk.used, disk.avail, disk.read_rate, disk.write_rate });
    std.debug.print("net rx {d:.0} tx {d:.0}; cpu cores {d}\n", .{ snapshot.network_rx, snapshot.network_tx, snapshot.cpu_core_count });

    var shell = try host.surface_composition.Composition.init(allocator, example_modules.modules,
        \\return require("lib.bar")
    );
    defer shell.deinit();
    var storage: status.StatusValues(Value) = .{};
    try shell.update(.{ .service = "status", .values = storage.build(&snapshot) });
    try shell.update(.{ .service = "frame", .values = &.{.{ .number = 250 }} });
    var frame = try shell.lower(.{ .width = width, .height = height });
    defer frame.deinit();
    var renderer = try graphics.skia.Renderer.init(true);
    defer renderer.deinit();
    try renderer.begin(width, height, .{ 0, 0, 0, 1 });
    renderer.drawList(frame.drawList());
    try writePpm(allocator, io, directory, "live", try renderer.end());
}

fn writePpm(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8, frame: graphics.skia.Frame) !void {
    var rgb = try allocator.alloc(u8, frame.width * frame.height * 3);
    defer allocator.free(rgb);
    for (0..frame.height) |y| for (0..frame.width) |x| {
        const source = y * frame.row_bytes + x * 4; // BGRA
        const target = (y * frame.width + x) * 3;
        rgb[target] = frame.pixels[source + 2];
        rgb[target + 1] = frame.pixels[source + 1];
        rgb[target + 2] = frame.pixels[source];
    };
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.ppm", .{ directory, name });
    defer allocator.free(path);
    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ frame.width, frame.height });
    defer allocator.free(header);
    const file = try allocator.alloc(u8, header.len + rgb.len);
    defer allocator.free(file);
    @memcpy(file[0..header.len], header);
    @memcpy(file[header.len..], rgb);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file });
}

fn number(value: f64) Value {
    return .{ .number = value };
}

fn populate(shell: *host.surface_composition.Composition, scenario: Scenario) !void {
    const first = [_]Value{
        .{ .string = "window" }, .{ .string = "" },     .{ .string = "foot" }, .{ .string = "nvim status.lua" },
        .{ .boolean = true },    number(196),           .{ .string = icon },   .{ .string = "" },
        number(0),               .{ .boolean = false },
    };
    const second = [_]Value{
        .{ .string = "window" }, .{ .string = "" },     .{ .string = "firefox" }, .{ .string = "Docs" },
        .{ .boolean = false },   number(196),           .{ .string = icon },      .{ .string = "" },
        number(200),             .{ .boolean = false },
    };
    const windows = [_]Value{ .{ .array = &first }, .{ .array = &second } };
    var occupied = [_]Value{.{ .boolean = false }} ** 9;
    occupied[0] = .{ .boolean = true };
    occupied[1] = .{ .boolean = true };
    occupied[3] = .{ .boolean = true };
    try shell.update(.{
        .service = "desktop",
        .values = &.{
            number(2),   .{ .array = &occupied }, .{ .array = &windows }, number(0),
            number(400), number(0),               number(0),              .{ .boolean = scenario.monitor_focused },
        },
    });

    var snapshot = status.Snapshot{};
    snapshot.time = "12:34".*;
    snapshot.dow = "Mon".*;
    snapshot.date = "2026-09-29".*;
    snapshot.cpu_core_count = 32;
    snapshot.cpu_core_equivalents = 12.4;
    snapshot.cpu_sample_sequence = 1;
    for (0..32) |index| snapshot.cpu_cores[index] = @max(0.0, 100.0 - @as(f64, @floatFromInt(index)) * 9.0);
    for (&snapshot.cpu_history, 0..) |*sample, index| sample.* = 2.0 + 10.0 * @abs(@sin(@as(f64, @floatFromInt(index)) * 0.4));
    if (scenario.spiky) for (&snapshot.cpu_history, 0..) |*sample, index| {
        sample.* = if (index < 6) 0.3 else if (index < 12) 9.0 else if (index < 18) 1.5 else 20.0;
    };
    snapshot.network_rx = 1.53e6;
    snapshot.network_tx = 322e3;
    snapshot.network_sample_sequence = 1;
    for (&snapshot.network_rx_history, &snapshot.network_tx_history, 0..) |*rx, *tx, index| {
        const t: f64 = @floatFromInt(index);
        rx.* = 300e3 + 900e3 * @abs(@sin(t * 0.35));
        tx.* = 40e3 + 160e3 * @abs(@cos(t * 0.5));
        if (scenario.spiky) {
            rx.* = if (index < 10) 20e3 else 175e6 * @exp(-(t - 10) / 6);
            tx.* = if (index < 10) 5e3 else 4e6 * @exp(-(t - 10) / 5);
        }
    }
    snapshot.audio_percent = 63;
    snapshot.audio_muted = scenario.muted;
    const gib: u64 = 1024 * 1024 * 1024;
    snapshot.memory = .{
        .total = 64 * gib,
        .used = 21 * gib + gib / 3,
        .cache = 14 * gib,
        .arc = 6 * gib,
        .free = 20 * gib,
        .swap_total = if (scenario.swap) 8 * gib else 0,
        .swap_used = if (scenario.swap) gib + gib / 5 else 0,
        .zswap_stored = if (scenario.swap) 3 * gib else 0,
        .zswap_compressed = if (scenario.swap) gib else 0,
    };
    const filesystems = [_]struct { []const u8, u64, u64, f64, f64 }{
        .{ "rpool", 1660, 1101, 4.2e6, 90e3 },
        .{ "scratchpool", 450, 24, 0, 0 },
        .{ "tank", 7373, 4198, 120e6, 3.4e6 },
        .{ "bulkpool", 21000, 12000, 0, 0 },
    };
    for (filesystems, 0..) |entry, index| {
        var disk = status.Disk{
            .label_len = @intCast(entry[0].len),
            .total = entry[1] * gib,
            .used = entry[2] * gib,
            .avail = (entry[1] - entry[2]) * gib,
            .read_rate = entry[3],
            .write_rate = entry[4],
        };
        @memcpy(disk.label[0..entry[0].len], entry[0]);
        snapshot.disks[index] = disk;
    }
    snapshot.disk_count = filesystems.len;
    snapshot.battery_present = scenario.battery;
    snapshot.battery_percent = 87;

    var storage: status.StatusValues(Value) = .{};
    try shell.update(.{ .service = "status", .values = storage.build(&snapshot) });
}
