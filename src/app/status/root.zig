//! Asynchronous system-status acquisition for surface programs.
//!
//! Every producer is an independent `std.Io` task. Consumers only copy the
//! latest in-memory snapshot; file, pipe, process, and timer waits never occur
//! in a Wayland callback or a Lua surface controller.

const std = @import("std");

pub const cpu_history_len = 15;
pub const network_history_len = 16;
pub const network_sample_period_ms = 500;

pub const Snapshot = struct {
    time: [5]u8 = "--:--".*,
    dow: [3]u8 = "---".*,
    date: [10]u8 = "----------".*,
    cpu_percent: u8 = 0,
    cpu_history: [cpu_history_len]f64 = [_]f64{0} ** cpu_history_len,
    memory_percent: u8 = 0,
    disk_percent: u8 = 0,
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io };
        errdefer self.group.cancel(io);
        try self.group.concurrent(io, clockLoop, .{self});
        try self.group.concurrent(io, cpuLoop, .{self});
        try self.group.concurrent(io, memoryLoop, .{self});
        try self.group.concurrent(io, diskLoop, .{self});
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
        var previous: ?CpuSample = null;
        while (true) {
            const current = readCpu(self.io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                try std.Io.sleep(self.io, .fromSeconds(2), .awake);
                continue;
            };
            var percent: u8 = 0;
            if (previous) |old| {
                const total = current.total -| old.total;
                const idle = current.idle -| old.idle;
                if (total != 0) percent = @intCast(@min(100, ((total -| idle) * 100 + total / 2) / total));
            }
            previous = current;
            self.lock();
            self.snapshot.cpu_percent = percent;
            pushBoundedHistory(cpu_history_len, &self.snapshot.cpu_history, @as(f64, @floatFromInt(percent)) / 100.0);
            self.publish();
            try std.Io.sleep(self.io, .fromSeconds(2), .awake);
        }
    }

    fn memoryLoop(self: *Service) std.Io.Cancelable!void {
        while (true) {
            const percent = readMemory(self.io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                try std.Io.sleep(self.io, .fromSeconds(5), .awake);
                continue;
            };
            self.lock();
            self.snapshot.memory_percent = percent;
            self.publish();
            try std.Io.sleep(self.io, .fromSeconds(5), .awake);
        }
    }

    fn diskLoop(self: *Service) std.Io.Cancelable!void {
        while (true) {
            const percent = self.pollDisk() catch |err| {
                if (err == error.Canceled) return error.Canceled;
                try std.Io.sleep(self.io, .fromSeconds(30), .awake);
                continue;
            };
            self.lock();
            self.snapshot.disk_percent = percent;
            self.publish();
            try std.Io.sleep(self.io, .fromSeconds(30), .awake);
        }
    }

    fn networkLoop(self: *Service) std.Io.Cancelable!void {
        var previous: ?NetworkSample = null;
        var previous_at: ?std.Io.Timestamp = null;
        var interface_buffer: [64]u8 = undefined;
        var interface: ?[]const u8 = null;
        while (true) {
            if (interface == null) interface = readDefaultInterface(self.io, &interface_buffer) catch |err| blk: {
                if (err == error.Canceled) return error.Canceled;
                break :blk null;
            };
            const current = if (interface) |name| readNetwork(self.io, name) catch |err| blk: {
                if (err == error.Canceled) return error.Canceled;
                break :blk null;
            } else null;
            const sample = current orelse {
                try std.Io.sleep(self.io, .fromMilliseconds(network_sample_period_ms), .awake);
                continue;
            };
            var rx: f64 = 0;
            var tx: f64 = 0;
            const now = std.Io.Clock.awake.now(self.io);
            if (previous) |old| {
                const elapsed_ns = (previous_at orelse now).durationTo(now).nanoseconds;
                const elapsed_seconds = @as(f64, @floatFromInt(@max(elapsed_ns, 1))) / std.time.ns_per_s;
                rx = @as(f64, @floatFromInt(sample.rx -| old.rx)) / elapsed_seconds;
                tx = @as(f64, @floatFromInt(sample.tx -| old.tx)) / elapsed_seconds;
            }
            previous = sample;
            previous_at = now;
            self.lock();
            self.snapshot.network_rx = rx;
            self.snapshot.network_tx = tx;
            pushRawHistory(&self.snapshot.network_rx_history, rx);
            pushRawHistory(&self.snapshot.network_tx_history, tx);
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

    fn pollDisk(self: *Service) !u8 {
        const output = try self.command(&.{ "df", "-P", "/" });
        defer self.allocator.free(output);
        var lines = std.mem.splitScalar(u8, output, '\n');
        _ = lines.next();
        const line = lines.next() orelse return error.InvalidDiskUsage;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        var use: ?[]const u8 = null;
        while (fields.next()) |field| {
            if (std.mem.endsWith(u8, field, "%")) use = field;
        }
        const value = use orelse return error.InvalidDiskUsage;
        return @intCast(@min(100, try std.fmt.parseUnsigned(u16, value[0 .. value.len - 1], 10)));
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
        };
    }

    fn command(self: *Service, argv: []const []const u8) ![]u8 {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(4096),
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
const NetworkSample = struct { rx: u64, tx: u64 };
const AudioSample = struct { percent: u8, muted: bool };
const BatterySample = struct { present: bool = false, percent: u8 = 0, charging: bool = false };

fn readCpu(io: std.Io) !CpuSample {
    var buffer: [1024]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFile(io, "/proc/stat", &buffer);
    const line = std.mem.sliceTo(data, '\n');
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidCpuStat, "cpu")) return error.InvalidCpuStat;
    var total: u64 = 0;
    var values: [5]u64 = [_]u64{0} ** 5;
    var count: usize = 0;
    while (fields.next()) |field| {
        const value = try std.fmt.parseUnsigned(u64, field, 10);
        if (count < values.len) values[count] = value;
        count += 1;
        total +|= value;
    }
    if (count < 4) return error.InvalidCpuStat;
    return .{ .total = total, .idle = values[3] +| values[4] };
}

fn readMemory(io: std.Io) !u8 {
    var buffer: [4096]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFile(io, "/proc/meminfo", &buffer);
    var total: ?u64 = null;
    var available: ?u64 = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " :\t");
        const name = fields.next() orelse continue;
        if (std.mem.eql(u8, name, "MemTotal")) total = try std.fmt.parseUnsigned(u64, fields.next() orelse continue, 10);
        if (std.mem.eql(u8, name, "MemAvailable")) available = try std.fmt.parseUnsigned(u64, fields.next() orelse continue, 10);
    }
    const capacity = total orelse return error.InvalidMemoryInfo;
    const free = available orelse return error.InvalidMemoryInfo;
    if (capacity == 0) return error.InvalidMemoryInfo;
    return @intCast(@min(100, ((capacity -| free) * 100 + capacity / 2) / capacity));
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

fn pushBoundedHistory(comptime len: usize, history: *[len]f64, value: f64) void {
    std.mem.copyForwards(f64, history[0 .. len - 1], history[1..]);
    history[len - 1] = @min(1.0, @max(0.0, value));
}

fn pushRawHistory(history: *[network_history_len]f64, value: f64) void {
    std.mem.copyForwards(f64, history[0 .. network_history_len - 1], history[1..]);
    history[network_history_len - 1] = if (std.math.isFinite(value)) @max(0, value) else 0;
}

test "history retains the latest bounded samples" {
    var history = [_]f64{0} ** cpu_history_len;
    pushBoundedHistory(cpu_history_len, &history, 0.25);
    pushBoundedHistory(cpu_history_len, &history, 2.0);
    try std.testing.expectEqual(@as(f64, 0.25), history[cpu_history_len - 2]);
    try std.testing.expectEqual(@as(f64, 1.0), history[cpu_history_len - 1]);
}

test "network history retains raw rates for drawing policy" {
    var history = [_]f64{0} ** network_history_len;
    pushRawHistory(&history, 256 * 1024);
    try std.testing.expectEqual(@as(f64, 256 * 1024), history[network_history_len - 1]);
}
