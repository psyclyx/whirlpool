//! Temperatures from `/sys/class/hwmon`: one reading per thing worth watching
//! (the CPU package, each drive, a GPU the kernel drives), not every sensor a
//! chip exposes. Discovery decides which input file stands for each; reading
//! is then one small file per sensor.

const std = @import("std");

pub const max_sensors = 8;

pub const Kind = enum { cpu, gpu, drive };

pub const Sensor = struct {
    kind: Kind,
    /// What it is called on the bar: `cpu`, `gpu`, or the drive's kernel name
    /// (`nvme0`, `sda`), which is also how drives match the disks they hold.
    label: [16]u8 = undefined,
    label_len: u8 = 0,
    /// The `tempN_input` file, relative to /sys/class/hwmon.
    input: [48]u8 = undefined,
    input_len: u8 = 0,
    /// The chip's critical temperature, in °C (0 when it states none).
    critical: f32 = 0,

    pub fn labelSlice(self: *const Sensor) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn inputSlice(self: *const Sensor) []const u8 {
        return self.input[0..self.input_len];
    }
};

/// Which input of a chip to read, by chip name: the label to look for among
/// its inputs (in order of preference), or none to take `temp1`.
const Choice = struct { chip: []const u8, kind: Kind, labels: []const []const u8 = &.{} };

const choices = [_]Choice{
    // Tdie is the die itself; Tctl may carry a fan-control offset.
    .{ .chip = "k10temp", .kind = .cpu, .labels = &.{ "Tdie", "Tctl" } },
    .{ .chip = "zenpower", .kind = .cpu, .labels = &.{ "Tdie", "Tctl" } },
    .{ .chip = "coretemp", .kind = .cpu, .labels = &.{"Package id 0"} },
    .{ .chip = "cpu_thermal", .kind = .cpu },
    .{ .chip = "amdgpu", .kind = .gpu, .labels = &.{ "edge", "junction" } },
    .{ .chip = "nvme", .kind = .drive, .labels = &.{"Composite"} },
    .{ .chip = "drivetemp", .kind = .drive },
};

/// Find the sensors worth reporting: the CPU first, then GPUs, then drives.
pub fn discover(io: std.Io, sensors: *[max_sensors]Sensor) usize {
    var count: usize = 0;
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/hwmon", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (count == max_sensors) break;
        var path: [96]u8 = undefined;
        var value: [64]u8 = undefined;
        const name_path = std.fmt.bufPrint(&path, "{s}/name", .{entry.name}) catch continue;
        const chip = std.mem.trim(u8, dir.readFile(io, name_path, &value) catch continue, " \n");
        const choice = for (choices) |candidate| {
            if (std.mem.eql(u8, candidate.chip, chip)) break candidate;
        } else continue;
        // A second CPU package (or chip driver) adds nothing on a bar.
        if (choice.kind == .cpu and for (sensors[0..count]) |sensor| {
            if (sensor.kind == .cpu) break true;
        } else false) continue;
        const index = pickInput(io, dir, entry.name, choice.labels) orelse continue;

        var sensor = Sensor{ .kind = choice.kind };
        const input = std.fmt.bufPrint(&sensor.input, "{s}/temp{d}_input", .{ entry.name, index }) catch continue;
        sensor.input_len = @intCast(input.len);
        const label = switch (choice.kind) {
            .cpu => "cpu",
            .gpu => "gpu",
            .drive => driveName(io, dir, entry.name, &value) orelse chip,
        };
        sensor.label_len = @intCast(@min(sensor.label.len, label.len));
        @memcpy(sensor.label[0..sensor.label_len], label[0..sensor.label_len]);
        const critical_path = std.fmt.bufPrint(&path, "{s}/temp{d}_crit", .{ entry.name, index }) catch continue;
        if (dir.readFile(io, critical_path, &value)) |text| {
            const millidegrees = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \n"), 10) catch 0;
            // Some chips report an impossible placeholder.
            if (millidegrees > 0 and millidegrees < 200_000) sensor.critical = @as(f32, @floatFromInt(millidegrees)) / 1000;
        } else |_| {}
        sensors[count] = sensor;
        count += 1;
    }
    std.mem.sort(Sensor, sensors[0..count], {}, struct {
        fn before(_: void, left: Sensor, right: Sensor) bool {
            if (left.kind != right.kind) return @intFromEnum(left.kind) < @intFromEnum(right.kind);
            return std.mem.order(u8, left.labelSlice(), right.labelSlice()) == .lt;
        }
    }.before);
    return count;
}

/// The input number whose label comes first in `labels`, else 1 when the chip
/// has a `temp1_input`.
fn pickInput(io: std.Io, dir: std.Io.Dir, chip_dir: []const u8, labels: []const []const u8) ?u8 {
    var path: [96]u8 = undefined;
    var value: [64]u8 = undefined;
    for (labels) |wanted| {
        for (1..16) |index| {
            const label_path = std.fmt.bufPrint(&path, "{s}/temp{d}_label", .{ chip_dir, index }) catch return null;
            const label = std.mem.trim(u8, dir.readFile(io, label_path, &value) catch continue, " \n");
            if (std.mem.eql(u8, label, wanted)) return @intCast(index);
        }
    }
    const first = std.fmt.bufPrint(&path, "{s}/temp1_input", .{chip_dir}) catch return null;
    _ = dir.readFile(io, first, &value) catch return null;
    return 1;
}

/// The kernel name of the drive a chip belongs to: an NVMe controller
/// (`nvme0`) or, for drivetemp, the SCSI disk's block device (`sda`).
fn driveName(io: std.Io, dir: std.Io.Dir, chip_dir: []const u8, buffer: []u8) ?[]const u8 {
    var path: [96]u8 = undefined;
    const device = std.fmt.bufPrint(&path, "{s}/device", .{chip_dir}) catch return null;
    const target = dir.readLink(io, device, buffer) catch return null;
    const name = std.fs.path.basename(buffer[0..target]);
    if (std.mem.startsWith(u8, name, "nvme")) return name;
    const block_path = std.fmt.bufPrint(&path, "{s}/device/block", .{chip_dir}) catch return null;
    var block = dir.openDir(io, block_path, .{ .iterate = true }) catch return null;
    defer block.close(io);
    var entries = block.iterate();
    const entry = (entries.next(io) catch return null) orelse return null;
    const length = @min(buffer.len, entry.name.len);
    @memcpy(buffer[0..length], entry.name[0..length]);
    return buffer[0..length];
}

/// A sensor's temperature in °C.
pub fn read(io: std.Io, sensor: *const Sensor) ?f64 {
    var path: [80]u8 = undefined;
    const location = std.fmt.bufPrint(&path, "/sys/class/hwmon/{s}", .{sensor.inputSlice()}) catch return null;
    var value: [32]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, location, &value) catch return null;
    const millidegrees = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \n"), 10) catch return null;
    return @as(f64, @floatFromInt(millidegrees)) / 1000;
}

/// Whether a block device (`nvme0n1p3`, `sda1`) is on the drive `label`
/// names (`nvme0`, `sda`).
pub fn onDrive(device: []const u8, label: []const u8) bool {
    if (!std.mem.startsWith(u8, device, label)) return false;
    if (device.len == label.len) return true;
    const next = device[label.len];
    // nvme0 holds nvme0n1, not nvme01n1; sda holds sda1, not sdab.
    return if (std.mem.startsWith(u8, label, "nvme")) next == 'n' else std.ascii.isDigit(next);
}

test "block devices belong to the drive that holds them" {
    try std.testing.expect(onDrive("nvme0n1p3", "nvme0"));
    try std.testing.expect(!onDrive("nvme10n1", "nvme1"));
    try std.testing.expect(onDrive("sda1", "sda"));
    try std.testing.expect(!onDrive("sdab1", "sda"));
    try std.testing.expect(onDrive("sda", "sda"));
}
