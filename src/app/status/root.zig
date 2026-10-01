//! Asynchronous system-status acquisition for surface programs.
//!
//! Every producer is an independent `std.Io` task. Consumers only copy the
//! latest in-memory snapshot; file, pipe, process, and timer waits never occur
//! in a Wayland callback or a Lua surface controller.

const std = @import("std");
const rate_mod = @import("rate.zig");
const storage = @import("storage.zig");
const io_mod = @import("io.zig");

pub const WindowedRate = rate_mod.WindowedRate;
pub const cpu_history_len = 24;
pub const network_history_len = 24;
pub const max_cpu_count = 256;
pub const cpu_sample_period_ms = 500;
pub const network_sample_period_ms = 500;
/// Throughput is bytes over this trailing window, so displayed numbers change
/// smoothly instead of tracking every sample.
const throughput_window_ns: i128 = 2 * std.time.ns_per_s;
/// The numeric readout averages over a longer window than the plot so it moves
/// slowly enough to read.
const readout_window_ns: i128 = 4 * std.time.ns_per_s;
pub const max_disks = storage.max_groups;

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

pub const Disk = struct {
    label: [24]u8 = undefined,
    label_len: u8 = 0,
    total: u64 = 0,
    used: u64 = 0,
    avail: u64 = 0,
    /// Bytes per second the pool or device is reading and writing.
    read_rate: f64 = 0,
    write_rate: f64 = 0,

    pub fn labelSlice(self: *const Disk) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const Snapshot = struct {
    time: [5]u8 = "--:--".*,
    dow: [3]u8 = "---".*,
    date: [10]u8 = "----------".*,
    cpu_percent: u8 = 0,
    cpu_history: [cpu_history_len]f64 = [_]f64{0} ** cpu_history_len,
    cpu_core_count: u16 = 0,
    cpu_core_equivalents: f64 = 0,
    cpu_cores: [max_cpu_count]f64 = [_]f64{0} ** max_cpu_count,
    cpu_sample_sequence: u64 = 0,
    memory: Memory = .{},
    disks: [max_disks]Disk = [_]Disk{.{}} ** max_disks,
    disk_count: u8 = 0,
    network_rx: f64 = 0,
    network_tx: f64 = 0,
    network_rx_history: [network_history_len]f64 = [_]f64{0} ** network_history_len,
    network_tx_history: [network_history_len]f64 = [_]f64{0} ** network_history_len,
    network_sample_sequence: u64 = 0,
    audio_percent: u8 = 0,
    audio_muted: bool = false,
    audio_visible: bool = false,
    battery_present: bool = false,
    battery_percent: u8 = 0,
    battery_charging: bool = false,
    battery_on_ac: bool = true,
};

pub const VersionedSnapshot = struct {
    revision: u64,
    value: Snapshot,
};

pub const Wake = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque) void,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    snapshot: Snapshot = .{},
    revision: u64 = 0,
    wake: ?Wake = null,
    /// What each reported filesystem lives on, so I/O can be attributed to it.
    /// Rewritten whenever the set of filesystems is rediscovered.
    disk_targets: [max_disks]IoTarget = [_]IoTarget{.{}} ** max_disks,
    disk_generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io };
        errdefer self.group.cancel(io);
        try self.group.concurrent(io, clockLoop, .{self});
        try self.group.concurrent(io, cpuLoop, .{self});
        try self.group.concurrent(io, memoryLoop, .{self});
        try self.group.concurrent(io, diskLoop, .{self});
        try self.group.concurrent(io, diskIoLoop, .{self});
        try self.group.concurrent(io, networkLoop, .{self});
        try self.group.concurrent(io, audioLoop, .{self});
        try self.group.concurrent(io, batteryLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Service) void {
        self.group.cancel(self.io);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn setWake(self: *Service, wake: Wake) void {
        self.lock();
        self.wake = wake;
        self.unlock();
    }

    pub fn clearWake(self: *Service) void {
        self.lock();
        self.wake = null;
        self.unlock();
    }

    /// Returns immediately; producers never hold this mutex while doing I/O.
    pub fn latestAfter(self: *Service, revision: u64) ?VersionedSnapshot {
        self.lock();
        defer self.unlock();
        if (self.revision == revision) return null;
        return .{ .revision = self.revision, .value = self.snapshot };
    }

    fn publish(self: *Service) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
        const wake = self.wake;
        self.unlock();
        if (wake) |callback| callback.run(callback.context);
    }

    fn lock(self: *Service) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Service) void {
        self.mutex.unlock(self.io);
    }

    fn clockLoop(self: *Service) std.Io.Cancelable!void {
        while (true) {
            self.pollClock() catch |err| if (err == error.Canceled) return error.Canceled;
            try std.Io.sleep(self.io, .fromSeconds(1), .awake);
        }
    }

    fn cpuLoop(self: *Service) std.Io.Cancelable!void {
        var previous: ?CpuRead = null;
        while (true) {
            const current = readCpu(self.io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                try std.Io.sleep(self.io, .fromSeconds(2), .awake);
                continue;
            };
            var aggregate: f64 = 0;
            var core_equivalents: f64 = 0;
            var core_percent = [_]f64{0} ** max_cpu_count;
            if (previous) |old| {
                aggregate = utilization(old.aggregate, current.aggregate);
                const count = @min(old.count, current.count);
                for (0..count) |index| {
                    const value = utilization(old.cores[index], current.cores[index]);
                    core_percent[index] = value * 100.0;
                    core_equivalents += value;
                }
            }
            previous = current;
            self.lock();
            self.snapshot.cpu_percent = @intFromFloat(@min(100.0, aggregate * 100.0 + 0.5));
            self.snapshot.cpu_core_count = @intCast(current.count);
            self.snapshot.cpu_core_equivalents = core_equivalents;
            self.snapshot.cpu_cores = core_percent;
            pushHistory(cpu_history_len, &self.snapshot.cpu_history, core_equivalents);
            self.snapshot.cpu_sample_sequence +|= 1;
            if (self.snapshot.cpu_sample_sequence == 0) self.snapshot.cpu_sample_sequence = 1;
            self.publish();
            try std.Io.sleep(self.io, .fromMilliseconds(cpu_sample_period_ms), .awake);
        }
    }

    fn memoryLoop(self: *Service) std.Io.Cancelable!void {
        while (true) {
            const memory = readMemory(self.io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                try std.Io.sleep(self.io, .fromSeconds(5), .awake);
                continue;
            };
            self.lock();
            self.snapshot.memory = memory;
            self.publish();
            try std.Io.sleep(self.io, .fromSeconds(2), .awake);
        }
    }

    fn diskLoop(self: *Service) std.Io.Cancelable!void {
        while (true) {
            var groups: [storage.max_groups]storage.Group = undefined;
            const count = self.pollDisks(&groups) catch |err| blk: {
                if (err == error.Canceled) return error.Canceled;
                break :blk 0;
            };
            var targets = [_]IoTarget{.{}} ** max_disks;
            for (groups[0..count], 0..) |group, index| targets[index] = self.ioTarget(group);
            self.lock();
            for (groups[0..count], 0..) |group, index| {
                var disk = Disk{ .label_len = group.label_len, .total = group.total, .used = group.used, .avail = group.avail };
                @memcpy(disk.label[0..group.label_len], group.labelSlice());
                self.snapshot.disks[index] = disk;
            }
            self.snapshot.disk_count = @intCast(count);
            self.disk_targets = targets;
            self.disk_generation +%= 1;
            self.publish();
            try std.Io.sleep(self.io, .fromSeconds(30), .awake);
        }
    }

    /// Work out which counters describe a filesystem's traffic.
    fn ioTarget(self: *Service, group: storage.Group) IoTarget {
        var target = IoTarget{};
        switch (group.kind) {
            .zfs => {
                target.kind = .zfs_pool;
                target.len = copyName(&target.name, group.keySlice());
            },
            .block => {
                var name = group.keySlice();
                var resolved: [128]u8 = undefined;
                if (std.mem.startsWith(u8, name, "/dev/mapper/") or std.mem.startsWith(u8, name, "/dev/disk/")) {
                    // Names like /dev/mapper/root are symlinks to /dev/dm-N.
                    if (std.Io.Dir.cwd().readLink(self.io, name, &resolved)) |length| {
                        name = resolved[0..length];
                    } else |_| return target;
                }
                const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return target;
                target.kind = .block_device;
                target.len = copyName(&target.name, name[slash + 1 ..]);
            },
        }
        return target;
    }

    fn diskIoLoop(self: *Service) std.Io.Cancelable!void {
        var rings: [max_disks]DiskRing = [_]DiskRing{.{}} ** max_disks;
        var seen_generation: u64 = std.math.maxInt(u64);
        while (true) {
            self.lock();
            const generation = self.disk_generation;
            const targets = self.disk_targets;
            const count: usize = self.snapshot.disk_count;
            self.unlock();
            if (generation != seen_generation) {
                // New set of filesystems: counters of the old ones mean nothing.
                rings = [_]DiskRing{.{}} ** max_disks;
                seen_generation = generation;
            }
            const now = std.Io.Clock.awake.now(self.io).nanoseconds;
            var read_rates = [_]f64{0} ** max_disks;
            var write_rates = [_]f64{0} ** max_disks;
            for (targets[0..count], 0..) |target, index| {
                const counters = self.readIo(target) orelse continue;
                rings[index].reads.push(now, counters.read);
                rings[index].writes.push(now, counters.written);
                read_rates[index] = rings[index].reads.rate(readout_window_ns);
                write_rates[index] = rings[index].writes.rate(readout_window_ns);
            }
            self.lock();
            if (self.disk_generation == generation) {
                for (0..count) |index| {
                    self.snapshot.disks[index].read_rate = read_rates[index];
                    self.snapshot.disks[index].write_rate = write_rates[index];
                }
                self.publish();
            } else self.unlock();
            try std.Io.sleep(self.io, .fromMilliseconds(500), .awake);
        }
    }

    fn readIo(self: *Service, target: IoTarget) ?io_mod.Counters {
        switch (target.kind) {
            .none => return null,
            .zfs_pool => {
                var path: [128]u8 = undefined;
                const location = std.fmt.bufPrint(&path, "/proc/spl/kstat/zfs/{s}/io", .{target.nameSlice()}) catch return null;
                var buffer: [4096]u8 = undefined;
                const data = std.Io.Dir.cwd().readFile(self.io, location, &buffer) catch return null;
                return io_mod.parseZfsPoolIo(data);
            },
            .block_device => {
                var buffer: [64 * 1024]u8 = undefined;
                const data = std.Io.Dir.cwd().readFile(self.io, "/proc/diskstats", &buffer) catch return null;
                return io_mod.parseDiskstats(data, target.nameSlice());
            },
        }
    }

    fn networkLoop(self: *Service) std.Io.Cancelable!void {
        var received = WindowedRate{};
        var sent = WindowedRate{};
        var interface_buffer: [64]u8 = undefined;
        var interface: ?[]const u8 = null;
        while (true) {
            if (interface == null) {
                interface = readDefaultInterface(self.io, &interface_buffer) catch |err| blk: {
                    if (err == error.Canceled) return error.Canceled;
                    break :blk null;
                };
            }
            const current = if (interface) |name| readNetwork(self.io, name) catch |err| blk: {
                if (err == error.Canceled) return error.Canceled;
                break :blk null;
            } else null;
            const sample = current orelse {
                try std.Io.sleep(self.io, .fromMilliseconds(network_sample_period_ms), .awake);
                continue;
            };
            const now = std.Io.Clock.awake.now(self.io).nanoseconds;
            received.push(now, sample.rx);
            sent.push(now, sample.tx);
            const rx = received.rate(throughput_window_ns);
            const tx = sent.rate(throughput_window_ns);
            self.lock();
            self.snapshot.network_rx = received.rate(readout_window_ns);
            self.snapshot.network_tx = sent.rate(readout_window_ns);
            pushHistory(network_history_len, &self.snapshot.network_rx_history, rx);
            pushHistory(network_history_len, &self.snapshot.network_tx_history, tx);
            self.snapshot.network_sample_sequence +|= 1;
            if (self.snapshot.network_sample_sequence == 0) self.snapshot.network_sample_sequence = 1;
            self.publish();
            try std.Io.sleep(self.io, .fromMilliseconds(network_sample_period_ms), .awake);
        }
    }

    fn audioLoop(self: *Service) std.Io.Cancelable!void {
        var previous: ?AudioSample = null;
        var visible_ticks: u8 = 0;
        while (true) {
            const current = self.pollAudio() catch |err| blk: {
                if (err == error.Canceled) return error.Canceled;
                break :blk null;
            };
            if (current) |sample| {
                if (previous) |old| {
                    if (old.percent != sample.percent or old.muted != sample.muted)
                        visible_ticks = 4;
                }
                previous = sample;
                self.lock();
                self.snapshot.audio_percent = sample.percent;
                self.snapshot.audio_muted = sample.muted;
                self.snapshot.audio_visible = visible_ticks != 0;
                self.publish();
            } else if (visible_ticks != 0) {
                self.lock();
                self.snapshot.audio_visible = true;
                self.publish();
            }
            visible_ticks -|= 1;
            try std.Io.sleep(self.io, .fromMilliseconds(500), .awake);
        }
    }

    fn batteryLoop(self: *Service) std.Io.Cancelable!void {
        while (true) {
            const sample = self.pollBattery() catch |err| blk: {
                if (err == error.Canceled) return error.Canceled;
                break :blk BatterySample{};
            };
            self.lock();
            self.snapshot.battery_present = sample.present;
            self.snapshot.battery_percent = sample.percent;
            self.snapshot.battery_charging = sample.charging;
            self.snapshot.battery_on_ac = sample.on_ac;
            self.publish();
            try std.Io.sleep(self.io, .fromSeconds(10), .awake);
        }
    }

    fn pollClock(self: *Service) !void {
        const output = try self.command(&.{ "date", "+%H:%M|%a|%F" });
        defer self.allocator.free(output);
        var fields = std.mem.splitScalar(u8, std.mem.trim(u8, output, " \r\n"), '|');
        const time = fields.next() orelse return error.InvalidClock;
        const dow = fields.next() orelse return error.InvalidClock;
        const date = fields.next() orelse return error.InvalidClock;
        if (time.len != 5 or dow.len != 3 or date.len != 10) return error.InvalidClock;
        self.lock();
        @memcpy(&self.snapshot.time, time);
        @memcpy(&self.snapshot.dow, dow);
        @memcpy(&self.snapshot.date, date);
        self.publish();
    }

    /// Discover the filesystems worth reporting and size each from the thing
    /// that owns its space. Returns how many groups were filled in.
    fn pollDisks(self: *Service, groups: *[storage.max_groups]storage.Group) !usize {
        var buffer: [64 * 1024]u8 = undefined;
        const mountinfo = try std.Io.Dir.cwd().readFile(self.io, "/proc/self/mountinfo", &buffer);
        const count = storage.selectGroups(mountinfo, groups);
        for (groups[0..count]) |*group| {
            const output = self.command(&.{ "df", "-PB1", "--", group.mountSlice() }) catch |err| switch (err) {
                error.CommandFailed, error.FileNotFound => continue,
                else => return err,
            };
            defer self.allocator.free(output);
            storage.parseDf(output, group) catch continue;
        }
        // Pools are sized by ZFS itself: `used` counts snapshots and child
        // datasets that are not mounted, and `avail` is usable space. Asked
        // unconditionally: a pool with nothing mounted has no mount to find it by.
        var total = count;
        if (self.command(&.{ "zfs", "list", "-Hp", "-d0", "-o", "name,used,avail" })) |output| {
            defer self.allocator.free(output);
            total = storage.applyZfsList(output, groups, count);
        } else |_| {}
        return storage.finalize(groups[0..total]);
    }

    fn pollAudio(self: *Service) !?AudioSample {
        const output = self.command(&.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(output);
        const marker = "Volume:";
        const start = (std.mem.indexOf(u8, output, marker) orelse return null) + marker.len;
        var fields = std.mem.tokenizeAny(u8, output[start..], " \t\r\n");
        const volume = try std.fmt.parseFloat(f64, fields.next() orelse return null);
        return .{
            .percent = @intFromFloat(@min(100.0, @max(0.0, volume * 100.0 + 0.5))),
            .muted = std.mem.indexOf(u8, output, "[MUTED]") != null,
        };
    }

    fn pollBattery(self: *Service) !BatterySample {
        const output = try self.command(&.{
            "sh",                                                                                                                                                                                                   "-c",
            "for p in /sys/class/power_supply/*; do [ \"$(cat \"$p/type\" 2>/dev/null)\" = Battery ] || continue; printf '%s|' \"$(cat \"$p/capacity\" 2>/dev/null)\"; cat \"$p/status\" 2>/dev/null; break; done",
        });
        defer self.allocator.free(output);
        const trimmed = std.mem.trim(u8, output, " \t\r\n");
        if (trimmed.len == 0) return .{};
        const separator = std.mem.indexOfScalar(u8, trimmed, '|') orelse return .{};
        return .{
            .present = true,
            .percent = @intCast(@min(100, try std.fmt.parseUnsigned(u16, trimmed[0..separator], 10))),
            .charging = std.mem.startsWith(u8, trimmed[separator + 1 ..], "Charging"),
            .on_ac = !std.mem.startsWith(u8, trimmed[separator + 1 ..], "Discharging"),
        };
    }

    fn command(self: *Service, argv: []const []const u8) ![]u8 {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
        });
        self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                self.allocator.free(result.stdout);
                return error.CommandFailed;
            },
            else => {
                self.allocator.free(result.stdout);
                return error.CommandFailed;
            },
        }
        return result.stdout;
    }
};

const CpuSample = struct { total: u64, idle: u64 };
const CpuRead = struct {
    aggregate: CpuSample,
    cores: [max_cpu_count]CpuSample = [_]CpuSample{.{ .total = 0, .idle = 0 }} ** max_cpu_count,
    count: usize = 0,
};
const NetworkSample = struct { rx: u64, tx: u64 };
const AudioSample = struct { percent: u8, muted: bool };
const BatterySample = struct { present: bool = false, percent: u8 = 0, charging: bool = false, on_ac: bool = true };

fn readCpu(io: std.Io) !CpuRead {
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

fn utilization(previous: CpuSample, current: CpuSample) f64 {
    const total = current.total -| previous.total;
    if (total == 0) return 0;
    const idle = current.idle -| previous.idle;
    return @min(1.0, @as(f64, @floatFromInt(total -| idle)) / @as(f64, @floatFromInt(total)));
}

fn readMemory(io: std.Io) !Memory {
    var buffer: [8192]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFile(io, "/proc/meminfo", &buffer);
    var arc: u64 = 0;
    var arc_buffer: [16 * 1024]u8 = undefined;
    if (std.Io.Dir.cwd().readFile(io, "/proc/spl/kstat/zfs/arcstats", &arc_buffer)) |stats| {
        arc = parseArcSize(stats);
    } else |_| {}
    return parseMemory(data, arc);
}

fn parseArcSize(stats: []const u8) u64 {
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

fn parseMemory(meminfo: []const u8, arc: u64) !Memory {
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

/// Where a filesystem's I/O counters live.
const IoTarget = struct {
    kind: enum { none, zfs_pool, block_device } = .none,
    name: [64]u8 = undefined,
    len: u8 = 0,

    fn nameSlice(self: *const IoTarget) []const u8 {
        return self.name[0..self.len];
    }
};

const DiskRing = struct { reads: WindowedRate = .{}, writes: WindowedRate = .{} };

fn copyName(target: *[64]u8, source: []const u8) u8 {
    const count = @min(target.len, source.len);
    @memcpy(target[0..count], source[0..count]);
    return @intCast(count);
}

fn readDefaultInterface(io: std.Io, buffer: []u8) ![]const u8 {
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

fn readNetwork(io: std.Io, interface: []const u8) !?NetworkSample {
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

fn pushHistory(comptime len: usize, history: *[len]f64, value: f64) void {
    std.mem.copyForwards(f64, history[0 .. len - 1], history[1..]);
    history[len - 1] = if (std.math.isFinite(value)) @max(0, value) else 0;
}

test "history retains finite nonnegative samples" {
    var history = [_]f64{0} ** cpu_history_len;
    pushHistory(cpu_history_len, &history, 0.25);
    pushHistory(cpu_history_len, &history, 2.0);
    try std.testing.expectEqual(@as(f64, 0.25), history[cpu_history_len - 2]);
    try std.testing.expectEqual(@as(f64, 2.0), history[cpu_history_len - 1]);
}

test "network history retains smoothed rates for drawing policy" {
    var history = [_]f64{0} ** network_history_len;
    pushHistory(network_history_len, &history, 256 * 1024);
    try std.testing.expectEqual(@as(f64, 256 * 1024), history[network_history_len - 1]);
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

/// Shape a snapshot into the grouped positional values the shell program
/// receives (see the header of `lua/whirlpool/shell.lua`). Generic over the
/// script value type so this module needs no dependency on the script layer;
/// the caller owns the storage the returned slice points into.
pub fn StatusValues(comptime Value: type) type {
    return struct {
        cpu_history: [cpu_history_len]Value = undefined,
        cpu_cores: [max_cpu_count]Value = undefined,
        rx_history: [network_history_len]Value = undefined,
        tx_history: [network_history_len]Value = undefined,
        cpu: [6]Value = undefined,
        network: [5]Value = undefined,
        audio: [3]Value = undefined,
        memory: [9]Value = undefined,
        disk_fields: [max_disks][6]Value = undefined,
        disks: [max_disks]Value = undefined,
        battery: [4]Value = undefined,
        top: [10]Value = undefined,

        pub fn build(self: *@This(), snapshot: *const Snapshot) []const Value {
            for (0..cpu_history_len) |index| self.cpu_history[index] = .{ .number = snapshot.cpu_history[index] };
            const core_count: usize = snapshot.cpu_core_count;
            for (0..core_count) |index| self.cpu_cores[index] = .{ .number = snapshot.cpu_cores[index] };
            for (0..network_history_len) |index| {
                self.rx_history[index] = .{ .number = snapshot.network_rx_history[index] };
                self.tx_history[index] = .{ .number = snapshot.network_tx_history[index] };
            }
            self.cpu = .{
                .{ .number = @floatFromInt(snapshot.cpu_percent) },
                .{ .number = snapshot.cpu_core_equivalents },
                .{ .number = @floatFromInt(snapshot.cpu_core_count) },
                .{ .array = self.cpu_cores[0..core_count] },
                .{ .array = &self.cpu_history },
                .{ .number = @floatFromInt(snapshot.cpu_sample_sequence) },
            };
            self.network = .{
                .{ .number = snapshot.network_rx },
                .{ .number = snapshot.network_tx },
                .{ .array = &self.rx_history },
                .{ .array = &self.tx_history },
                .{ .number = @floatFromInt(snapshot.network_sample_sequence) },
            };
            self.audio = .{
                .{ .number = @floatFromInt(snapshot.audio_percent) },
                .{ .boolean = snapshot.audio_muted },
                .{ .boolean = snapshot.audio_visible },
            };
            const memory = snapshot.memory;
            self.memory = .{
                .{ .number = @floatFromInt(memory.total) },
                .{ .number = @floatFromInt(memory.used) },
                .{ .number = @floatFromInt(memory.cache) },
                .{ .number = @floatFromInt(memory.arc) },
                .{ .number = @floatFromInt(memory.free) },
                .{ .number = @floatFromInt(memory.swap_total) },
                .{ .number = @floatFromInt(memory.swap_used) },
                .{ .number = @floatFromInt(memory.zswap_stored) },
                .{ .number = @floatFromInt(memory.zswap_compressed) },
            };
            const disk_count: usize = snapshot.disk_count;
            for (0..disk_count) |index| {
                const disk = &snapshot.disks[index];
                self.disk_fields[index] = .{
                    .{ .string = disk.labelSlice() },
                    .{ .number = @floatFromInt(disk.total) },
                    .{ .number = @floatFromInt(disk.used) },
                    .{ .number = @floatFromInt(disk.avail) },
                    .{ .number = disk.read_rate },
                    .{ .number = disk.write_rate },
                };
                self.disks[index] = .{ .array = &self.disk_fields[index] };
            }
            self.battery = .{
                .{ .boolean = snapshot.battery_present },
                .{ .number = @floatFromInt(snapshot.battery_percent) },
                .{ .boolean = snapshot.battery_charging },
                .{ .boolean = snapshot.battery_on_ac },
            };
            self.top = .{
                .{ .string = &snapshot.time },
                .{ .string = &snapshot.dow },
                .{ .string = &snapshot.date },
                .{ .array = &self.cpu },
                .{ .array = &self.network },
                .{ .array = &self.audio },
                .{ .array = &self.memory },
                .{ .array = self.disks[0..disk_count] },
                .{ .array = &self.battery },
                .{ .boolean = snapshot.audio_visible },
            };
            return &self.top;
        }
    };
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

test "status values group every subsystem for the shell program" {
    const TestValue = union(enum) { number: f64, string: []const u8, boolean: bool, array: []const @This() };
    var snapshot = Snapshot{};
    snapshot.cpu_core_count = 2;
    snapshot.cpu_cores[0] = 90;
    snapshot.cpu_core_equivalents = 1.5;
    snapshot.memory = .{ .total = 100, .used = 40, .cache = 30, .arc = 10, .free = 20 };
    snapshot.disk_count = 1;
    var disk = Disk{ .label_len = 4, .total = 1000, .used = 400, .avail = 600 };
    @memcpy(disk.label[0..4], "tank");
    snapshot.disks[0] = disk;
    var storage_values: StatusValues(TestValue) = .{};
    const values = storage_values.build(&snapshot);
    try std.testing.expectEqual(@as(usize, 10), values.len);
    try std.testing.expectEqual(@as(usize, 2), values[3].array[3].array.len);
    try std.testing.expectEqual(@as(f64, 40), values[6].array[1].number);
    try std.testing.expectEqual(@as(usize, 1), values[7].array.len);
    try std.testing.expectEqualStrings("tank", values[7].array[0].array[0].string);
    try std.testing.expectEqual(@as(f64, 600), values[7].array[0].array[3].number);
}

test {
    _ = rate_mod;
    _ = storage;
    _ = io_mod;
}

test "live host: memory accounts for all of RAM and disks are grouped" {
    const memory = readMemory(std.testing.io) catch return error.SkipZigTest;
    try std.testing.expect(memory.total > 0);
    try std.testing.expectEqual(memory.total, memory.used + memory.cache + memory.arc + memory.free);

    var buffer: [64 * 1024]u8 = undefined;
    const mountinfo = std.Io.Dir.cwd().readFile(std.testing.io, "/proc/self/mountinfo", &buffer) catch return error.SkipZigTest;
    var groups: [storage.max_groups]storage.Group = undefined;
    const count = storage.selectGroups(mountinfo, &groups);
    for (groups[0..count], 0..) |group, index| {
        std.debug.print("live disk group {d}: {s} at {s} ({s})\n", .{ index, group.labelSlice(), group.mountSlice(), @tagName(group.kind) });
        for (groups[index + 1 .. count]) |other| {
            try std.testing.expect(!(group.kind == other.kind and std.mem.eql(u8, group.keySlice(), other.keySlice())));
        }
    }
    std.debug.print("live memory: total {d} used {d} cache {d} arc {d} free {d} swap {d}/{d}\n", .{
        memory.total, memory.used, memory.cache, memory.arc, memory.free, memory.swap_used, memory.swap_total,
    });
}
