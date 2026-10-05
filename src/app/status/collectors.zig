//! Readers for operating-system measurements. Each returns raw values (counters
//! stay cumulative); turning them into rates, levels or charts is the
//! consumer's business. Readers block on I/O and run on source tasks only.

const std = @import("std");
const storage = @import("storage.zig");
const io_mod = @import("io.zig");

pub const max_cpu_count = 256;

pub const Memory = struct {
    total: u64 = 0,
    /// Memory held by programs and the kernel (excluding everything below).
    used: u64 = 0,
    /// Page cache and buffers: reclaimable, but not free.
    cache: u64 = 0,
    /// ZFS ARC, evictable like cache but accounted separately by the kernel.
    arc: u64 = 0,
    free: u64 = 0,
    swap_total: u64 = 0,
    swap_used: u64 = 0,
    /// Pages held compressed in zswap (their original size), and the memory
    /// their compressed copies occupy. Both zero when zswap is off.
    zswap_stored: u64 = 0,
    zswap_compressed: u64 = 0,
};

pub const CpuSample = struct { total: u64, idle: u64 };
pub const CpuRead = struct {
    aggregate: CpuSample,
    cores: [max_cpu_count]CpuSample = [_]CpuSample{.{ .total = 0, .idle = 0 }} ** max_cpu_count,
    count: usize = 0,
};
pub const NetworkSample = struct { rx: u64, tx: u64 };


pub fn readCpu(io: std.Io) !CpuRead {
    var buffer: [32 * 1024]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFile(io, "/proc/stat", &buffer);
    var lines = std.mem.splitScalar(u8, data, '\n');
    const aggregate_line = lines.next() orelse return error.InvalidCpuStat;
    const aggregate = try parseCpuLine(aggregate_line, "cpu");
    var result = CpuRead{ .aggregate = aggregate };
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const label = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, label, "cpu") or label.len == 3) break;
        if (result.count == max_cpu_count) break;
        result.cores[result.count] = try parseCpuFields(&fields);
        result.count += 1;
    }
    if (result.count == 0) return error.InvalidCpuStat;
    return result;
}

fn parseCpuLine(line: []const u8, expected_label: []const u8) !CpuSample {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidCpuStat, expected_label))
        return error.InvalidCpuStat;
    return parseCpuFields(&fields);
}

fn parseCpuFields(fields: anytype) !CpuSample {
    var total: u64 = 0;
    var values: [5]u64 = [_]u64{0} ** 5;
    var count: usize = 0;
    while (fields.next()) |field| {
        const value = try std.fmt.parseUnsigned(u64, field, 10);
        if (count < values.len) values[count] = value;
        // guest and guest_nice are already included in user and nice.
        if (count < 8) total +|= value;
        count += 1;
    }
    if (count < 4) return error.InvalidCpuStat;
    return .{ .total = total, .idle = values[3] +| values[4] };
}

pub fn utilization(previous: CpuSample, current: CpuSample) f64 {
    const total = current.total -| previous.total;
    if (total == 0) return 0;
    const idle = current.idle -| previous.idle;
    return @min(1.0, @as(f64, @floatFromInt(total -| idle)) / @as(f64, @floatFromInt(total)));
}

pub fn readMemory(io: std.Io) !Memory {
    var buffer: [8192]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFile(io, "/proc/meminfo", &buffer);
    var arc: u64 = 0;
    var arc_buffer: [16 * 1024]u8 = undefined;
    if (std.Io.Dir.cwd().readFile(io, "/proc/spl/kstat/zfs/arcstats", &arc_buffer)) |stats| {
        arc = parseArcSize(stats);
    } else |_| {}
    return parseMemory(data, arc);
}

pub fn parseArcSize(stats: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, stats, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, "size")) continue;
        _ = fields.next() orelse continue; // kstat type
        return std.fmt.parseUnsigned(u64, fields.next() orelse continue, 10) catch 0;
    }
    return 0;
}

pub fn parseMemory(meminfo: []const u8, arc: u64) !Memory {
    var total: ?u64 = null;
    var free: u64 = 0;
    var buffers: u64 = 0;
    var cached: u64 = 0;
    var reclaimable: u64 = 0;
    var shared: u64 = 0;
    var swap_total: u64 = 0;
    var swap_free: u64 = 0;
    var zswap: u64 = 0;
    var zswapped: u64 = 0;
    var lines = std.mem.splitScalar(u8, meminfo, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " :\t");
        const name = fields.next() orelse continue;
        const kib = std.fmt.parseUnsigned(u64, fields.next() orelse continue, 10) catch continue;
        const bytes = kib * 1024;
        if (std.mem.eql(u8, name, "MemTotal")) total = bytes;
        if (std.mem.eql(u8, name, "MemFree")) free = bytes;
        if (std.mem.eql(u8, name, "Buffers")) buffers = bytes;
        if (std.mem.eql(u8, name, "Cached")) cached = bytes;
        if (std.mem.eql(u8, name, "SReclaimable")) reclaimable = bytes;
        if (std.mem.eql(u8, name, "Shmem")) shared = bytes;
        if (std.mem.eql(u8, name, "SwapTotal")) swap_total = bytes;
        if (std.mem.eql(u8, name, "SwapFree")) swap_free = bytes;
        if (std.mem.eql(u8, name, "Zswap")) zswap = bytes;
        if (std.mem.eql(u8, name, "Zswapped")) zswapped = bytes;
    }
    const capacity = total orelse return error.InvalidMemoryInfo;
    if (capacity == 0) return error.InvalidMemoryInfo;
    // Shared memory is counted in Cached but cannot be dropped like cache.
    const cache = (buffers +| cached +| reclaimable) -| shared;
    const arc_held = @min(arc, capacity);
    return .{
        .total = capacity,
        .used = capacity -| free -| cache -| arc_held,
        .cache = cache,
        .arc = arc_held,
        .free = free,
        .swap_total = swap_total,
        .swap_used = swap_total -| swap_free,
        .zswap_stored = zswapped,
        .zswap_compressed = zswap,
    };
}


pub fn readDefaultInterface(io: std.Io, buffer: []u8) ![]const u8 {
    var route_buffer: [4096]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFile(io, "/proc/net/route", &route_buffer);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const destination = fields.next() orelse continue;
        if (!std.mem.eql(u8, destination, "00000000")) continue;
        if (name.len > buffer.len) return error.InterfaceNameTooLong;
        @memcpy(buffer[0..name.len], name);
        return buffer[0..name.len];
    }
    return error.DefaultInterfaceNotFound;
}

pub fn readNetwork(io: std.Io, interface: []const u8) !?NetworkSample {
    var buffer: [4096]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFile(io, "/proc/net/dev", &buffer);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..separator], " \t"), interface)) continue;
        var fields = std.mem.tokenizeAny(u8, line[separator + 1 ..], " \t");
        const rx = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidNetworkInfo, 10);
        var index: usize = 1;
        while (index < 8) : (index += 1) _ = fields.next() orelse return error.InvalidNetworkInfo;
        const tx = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidNetworkInfo, 10);
        return .{ .rx = rx, .tx = tx };
    }
    return null;
}

test "cpu parser excludes guest time and retains logical cores" {
    const aggregate = try parseCpuLine("cpu  10 2 3 40 5 6 7 8 9 10", "cpu");
    try std.testing.expectEqual(@as(u64, 81), aggregate.total);
    try std.testing.expectEqual(@as(u64, 45), aggregate.idle);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), utilization(
        .{ .total = 100, .idle = 50 },
        .{ .total = 120, .idle = 60 },
    ), 0.0001);
}

test "memory parsing separates programs, cache, ZFS ARC, free and swap" {
    const kib = 1024;
    const memory = try parseMemory(
        \\MemTotal:       65536000 kB
        \\MemFree:        20480000 kB
        \\MemAvailable:   40000000 kB
        \\Buffers:          512000 kB
        \\Cached:         14000000 kB
        \\SReclaimable:     488000 kB
        \\Shmem:           1000000 kB
        \\SwapTotal:       8388608 kB
        \\SwapFree:        7000000 kB
        \\Zswap:             300000 kB
        \\Zswapped:          900000 kB
        \\
    , 6 * 1024 * 1024 * kib);
    try std.testing.expectEqual(@as(u64, 65536000 * kib), memory.total);
    try std.testing.expectEqual(@as(u64, 20480000 * kib), memory.free);
    // Buffers + Cached + SReclaimable - Shmem
    try std.testing.expectEqual(@as(u64, (512000 + 14000000 + 488000 - 1000000) * kib), memory.cache);
    try std.testing.expectEqual(@as(u64, 6 * 1024 * 1024 * kib), memory.arc);
    // The four parts account for the whole of RAM.
    try std.testing.expectEqual(memory.total, memory.used + memory.cache + memory.arc + memory.free);
    try std.testing.expectEqual(@as(u64, (8388608 - 7000000) * kib), memory.swap_used);
    try std.testing.expectEqual(@as(u64, 900000 * kib), memory.zswap_stored);
    try std.testing.expectEqual(@as(u64, 300000 * kib), memory.zswap_compressed);
}

test "arc size comes from the kstat table" {
    try std.testing.expectEqual(@as(u64, 6442450944), parseArcSize(
        \\13 1 0x01 147 39984 1234 5678
        \\name                            type data
        \\hits                            4    111
        \\size                            4    6442450944
        \\c_max                           4    9999
        \\
    ));
    try std.testing.expectEqual(@as(u64, 0), parseArcSize("nothing here\n"));
}


pub const Battery = struct { present: bool = false, percent: u8 = 0, charging: bool = false, on_ac: bool = true };

/// The first battery under `/sys/class/power_supply`, read directly.
pub fn readBattery(io: std.Io) !Battery {
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/power_supply", .{ .iterate = true }) catch return .{};
    defer dir.close(io);
    var iterator = dir.iterate();
    var on_ac = true;
    var battery: Battery = .{};
    while (try iterator.next(io)) |entry| {
        var path_buffer: [256]u8 = undefined;
        var value_buffer: [64]u8 = undefined;
        const type_path = std.fmt.bufPrint(&path_buffer, "{s}/type", .{entry.name}) catch continue;
        const kind = std.mem.trim(u8, dir.readFile(io, type_path, &value_buffer) catch continue, " \n");
        if (std.mem.eql(u8, kind, "Mains")) {
            const online_path = std.fmt.bufPrint(&path_buffer, "{s}/online", .{entry.name}) catch continue;
            const online = std.mem.trim(u8, dir.readFile(io, online_path, &value_buffer) catch continue, " \n");
            on_ac = std.mem.eql(u8, online, "1");
            continue;
        }
        if (!std.mem.eql(u8, kind, "Battery") or battery.present) continue;
        const capacity_path = std.fmt.bufPrint(&path_buffer, "{s}/capacity", .{entry.name}) catch continue;
        const capacity = std.mem.trim(u8, dir.readFile(io, capacity_path, &value_buffer) catch continue, " \n");
        battery.present = true;
        battery.percent = @intCast(@min(100, std.fmt.parseUnsigned(u16, capacity, 10) catch 0));
        const status_path = std.fmt.bufPrint(&path_buffer, "{s}/status", .{entry.name}) catch continue;
        const status = std.mem.trim(u8, dir.readFile(io, status_path, &value_buffer) catch "", " \n");
        battery.charging = std.mem.startsWith(u8, status, "Charging");
        if (std.mem.startsWith(u8, status, "Discharging")) on_ac = false;
    }
    battery.on_ac = on_ac;
    return battery;
}

/// Run `argv` and return its standard output; a nonzero exit is an error.
pub fn command(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
    });
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.CommandFailed;
}

pub const max_disks = storage.max_groups;

/// One filesystem worth reporting: its space, the block devices its traffic
/// goes to (a pool's leaf devices, or the one device a filesystem is mounted
/// from), and, for a pool, its health.
pub const Disk = struct {
    group: storage.Group,
    devices: [storage.max_devices]storage.DeviceName = undefined,
    device_count: u8 = 0,
    /// `ONLINE`, `DEGRADED`, ...; empty for anything but a pool.
    state: [16]u8 = undefined,
    state_len: u8 = 0,
    /// Files the pool knows to be damaged.
    data_errors: u32 = 0,

    pub fn deviceSlice(self: *const Disk) []const storage.DeviceName {
        return self.devices[0..self.device_count];
    }

    pub fn stateSlice(self: *const Disk) []const u8 {
        return self.state[0..self.state_len];
    }
};

/// Find the filesystems worth reporting and size each from what owns its space.
pub fn discoverDisks(allocator: std.mem.Allocator, io: std.Io, disks: *[max_disks]Disk) !usize {
    var buffer: [64 * 1024]u8 = undefined;
    const mountinfo = try std.Io.Dir.cwd().readFile(io, "/proc/self/mountinfo", &buffer);
    var groups: [storage.max_groups]storage.Group = undefined;
    const count = storage.selectGroups(mountinfo, &groups);
    for (groups[0..count]) |*group| {
        const output = command(allocator, io, &.{ "df", "-PB1", "--", group.mountSlice() }) catch |err| switch (err) {
            error.CommandFailed, error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(output);
        storage.parseDf(output, group) catch continue;
    }
    // Pools are sized by ZFS itself: `used` counts snapshots and child datasets
    // that are not mounted, and `avail` is usable space. Asked unconditionally:
    // a pool with nothing mounted has no mount to find it by.
    var total = count;
    if (command(allocator, io, &.{ "zfs", "list", "-Hp", "-d0", "-o", "name,used,avail" })) |output| {
        defer allocator.free(output);
        total = storage.applyZfsList(output, &groups, count);
    } else |_| {}
    // Which devices each pool's traffic goes to, and its health.
    var pools: [storage.max_groups]storage.PoolStatus = undefined;
    var pool_count: usize = 0;
    if (command(allocator, io, &.{ "zpool", "status", "-LP" })) |output| {
        defer allocator.free(output);
        pool_count = storage.parseZpoolStatus(output, &pools);
    } else |_| {}
    const kept = storage.finalize(groups[0..total]);
    for (groups[0..kept], 0..) |group, index| {
        var disk = Disk{ .group = group };
        switch (group.kind) {
            .zfs => for (pools[0..pool_count]) |*pool| {
                if (!std.mem.eql(u8, pool.nameSlice(), group.keySlice())) continue;
                disk.devices = pool.devices;
                disk.device_count = pool.device_count;
                disk.state = pool.state;
                disk.state_len = pool.state_len;
                disk.data_errors = pool.data_errors;
            },
            .block => if (blockDevice(io, group.keySlice())) |device| {
                disk.devices[0] = device;
                disk.device_count = 1;
            },
        }
        disks[index] = disk;
    }
    return kept;
}

/// The kernel name of the device a filesystem is mounted from: names like
/// /dev/mapper/root are symlinks to /dev/dm-N.
fn blockDevice(io: std.Io, source: []const u8) ?storage.DeviceName {
    var resolved: [128]u8 = undefined;
    var name = source;
    if (std.mem.startsWith(u8, name, "/dev/mapper/") or std.mem.startsWith(u8, name, "/dev/disk/")) {
        const length = std.Io.Dir.cwd().readLink(io, name, &resolved) catch return null;
        name = resolved[0..length];
    }
    if (!std.mem.startsWith(u8, name, "/dev/") and std.mem.indexOfScalar(u8, name, '/') != null) return null;
    return storage.DeviceName.from(name);
}

/// Cumulative bytes read and written for a disk: the sum over its devices,
/// from `diskstats` (the text of /proc/diskstats, read once for all disks).
pub fn diskCounters(diskstats: []const u8, disk: *const Disk) ?io_mod.Counters {
    var total = io_mod.Counters{ .read = 0, .written = 0 };
    var found = false;
    for (disk.deviceSlice()) |*device| {
        const counters = io_mod.parseDiskstats(diskstats, device.slice()) orelse continue;
        total.read +|= counters.read;
        total.written +|= counters.written;
        found = true;
    }
    return if (found) total else null;
}

pub fn readDiskstats(io: std.Io, buffer: []u8) ![]u8 {
    return std.Io.Dir.cwd().readFile(io, "/proc/diskstats", buffer);
}

test {
    _ = storage;
    _ = io_mod;
}

pub const Gpu = struct { busy: f64 = 0, temperature: f64 = 0, memory_used: f64 = 0, memory_total: f64 = 0, power: f64 = 0 };

/// One line of `nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,
/// memory.used,memory.total,power.draw --format=csv,noheader,nounits`.
/// Memory is reported in MiB; a field the card does not report (`[N/A]`)
/// reads as 0.
pub fn parseGpu(line: []const u8) ?Gpu {
    var values: [5]f64 = undefined;
    var fields = std.mem.splitScalar(u8, line, ',');
    for (&values) |*value| {
        const field = std.mem.trim(u8, fields.next() orelse return null, " ");
        value.* = std.fmt.parseFloat(f64, field) catch 0;
    }
    const mib = 1024 * 1024;
    return .{ .busy = values[0], .temperature = values[1], .memory_used = values[2] * mib, .memory_total = values[3] * mib, .power = values[4] };
}

test "gpu figures come from nvidia-smi's csv" {
    const gpu = parseGpu("36, 61, 2727, 24576, 122.16").?;
    try std.testing.expectEqual(@as(f64, 36), gpu.busy);
    try std.testing.expectEqual(@as(f64, 61), gpu.temperature);
    try std.testing.expectEqual(@as(f64, 24576 * 1024 * 1024), gpu.memory_total);
    try std.testing.expectEqual(@as(f64, 0), parseGpu("5, 40, 100, 200, [N/A]").?.power);
    try std.testing.expect(parseGpu("garbage") == null);
}

pub const CpuFrequency = struct { average_mhz: f64 = 0, max_mhz: f64 = 0 };

/// Each core's clock from cpufreq: the measured average over the last tick
/// (`cpuinfo_avg_freq`, from APERF/MPERF) where the kernel has it, else the
/// governor's current setting. Averaged and maximised over `count` cores.
pub fn readCpuFrequency(io: std.Io, count: usize) CpuFrequency {
    var result = CpuFrequency{};
    var total: f64 = 0;
    var read: usize = 0;
    for (0..count) |core| {
        var path: [80]u8 = undefined;
        var value: [32]u8 = undefined;
        const khz = for ([_][]const u8{ "cpuinfo_avg_freq", "scaling_cur_freq" }) |file| {
            const location = std.fmt.bufPrint(&path, "/sys/devices/system/cpu/cpu{d}/cpufreq/{s}", .{ core, file }) catch break null;
            const text = std.Io.Dir.cwd().readFile(io, location, &value) catch continue;
            break std.fmt.parseUnsigned(u64, std.mem.trim(u8, text, " \n"), 10) catch continue;
        } else null;
        const mhz = @as(f64, @floatFromInt(khz orelse continue)) / 1000;
        total += mhz;
        read += 1;
        result.max_mhz = @max(result.max_mhz, mhz);
    }
    if (read > 0) result.average_mhz = total / @as(f64, @floatFromInt(read));
    return result;
}

/// The default sink's volume, from `pactl get-sink-volume` ("Volume:
/// front-left: 22734 /  35% / -27.59 dB, ..."): the first channel's percent.
pub fn parsePactlVolume(output: []const u8) ?u16 {
    const percent = std.mem.indexOfScalar(u8, output, '%') orelse return null;
    var start = percent;
    while (start > 0 and std.ascii.isDigit(output[start - 1])) start -= 1;
    return std.fmt.parseUnsigned(u16, output[start..percent], 10) catch null;
}

/// Whether `pactl get-sink-mute` says "Mute: yes".
pub fn parsePactlMute(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "Mute: yes") != null;
}

test "pactl reports the sink's volume and mute" {
    try std.testing.expectEqual(@as(?u16, 35), parsePactlVolume("Volume: front-left: 22734 /  35% / -27.59 dB,   front-right: 22734 /  35% / -27.59 dB\n        balance 0.00\n"));
    try std.testing.expectEqual(@as(?u16, 150), parsePactlVolume("Volume: mono: 98304 / 150% / 10.57 dB\n"));
    try std.testing.expect(parsePactlVolume("nothing") == null);
    try std.testing.expect(parsePactlMute("Mute: yes\n"));
    try std.testing.expect(!parsePactlMute("Mute: no\n"));
}
