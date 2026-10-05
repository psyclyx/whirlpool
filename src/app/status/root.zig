//! System measurements as keyed, timestamped sources.
//!
//! The configuration registers sources by name (`whirlpool.source`). Each runs
//! as its own `std.Io` task at its own period and records raw samples, a time
//! and a value per field, in a ring covering its retention window. Counters
//! (network and disk bytes) stay cumulative: rates, smoothing, zoom and every
//! other way of looking at the data belong to whoever draws it, and can be
//! computed at any frame because each sample knows when it was taken.
//!
//! Times are milliseconds on the `origin` clock the host also uses for frame
//! ticks, so a consumer can place a sample at `now - t` exactly.
//!
//! Consumers copy encoded samples out under the service lock; no file, pipe,
//! process, or timer wait ever happens on a consumer's thread. Sources that
//! can be told about changes listen rather than poll: audio follows
//! `pactl subscribe`, and the GPU is read from `nvidia-smi`'s own loop, each
//! blocking on a pipe in its own task.

const std = @import("std");
const collectors = @import("collectors.zig");
const hwmon = @import("hwmon.zig");
const addresses = @import("addresses.zig");
const stream = @import("stream.zig");

pub const Kind = enum { cpu, memory, network, disks, sensors, gpu, audio, battery, command };

pub const Spec = struct {
    name: []const u8,
    kind: Kind,
    every_ms: u32 = 1000,
    keep_ms: u32 = 30_000,
    /// The program a `command` source runs, and its arguments.
    argv: []const []const u8 = &.{},
};

pub const max_sources = 32;
pub const max_samples = 256;
pub const max_fields = 10;
pub const max_disks = collectors.max_disks;
pub const max_sensors = hwmon.max_sensors;
const max_text = 4096;
/// How often a disks or sensors source looks again for what to report.
const disk_discovery_ms = 30_000;
/// How often a network source looks again at addresses (they change rarely).
const address_ms = 5_000;
/// How long a listening source waits before starting its program again, when
/// it exited or could not start.
const restart_ms = 5_000;

/// Field names of each kind's samples, in `Sample.fields` order.
fn fieldNames(kind: Kind) []const []const u8 {
    return switch (kind) {
        // Busy cores' worth, percent of the whole; clock speed in MHz, the
        // average over cores and the fastest core.
        .cpu => &.{ "busy", "percent", "mhz", "mhz_max" },
        .memory => &.{ "total", "used", "cache", "arc", "free", "swap_total", "swap_used", "zswap_stored", "zswap_compressed" },
        .network => &.{ "rx", "tx" },
        // Per disk: cumulative bytes read and written, two fields each.
        .disks => &.{},
        // Per sensor: °C, one field each.
        .sensors => &.{},
        // Percent busy, °C, memory used and total (bytes), watts.
        .gpu => &.{ "busy", "temperature", "memory_used", "memory_total", "power" },
        .audio => &.{ "percent", "muted" },
        .battery => &.{ "present", "percent", "charging", "on_ac" },
        .command => &.{},
    };
}

pub const Sample = struct {
    t: f64,
    fields: [max_fields]f64 = [_]f64{0} ** max_fields,
};

const Source = struct {
    name: []u8,
    kind: Kind,
    every_ms: u32,
    keep_ms: u32,
    argv: [][]u8,
    revision: u64 = 0,
    ring: [max_samples]Sample = undefined,
    start: usize = 0,
    len: usize = 0,
    // Latest state that is not a series.
    cpu_count: u16 = 0,
    cpu_cores: [collectors.max_cpu_count]f32 = [_]f32{0} ** collectors.max_cpu_count,
    interface: [64]u8 = undefined,
    interface_len: usize = 0,
    address: addresses.Address = .{},
    address6: addresses.Address = .{},
    tunnels: [addresses.max_tunnels]addresses.Address = undefined,
    tunnel_count: usize = 0,
    disks: [max_disks]collectors.Disk = undefined,
    disk_count: usize = 0,
    sensors: [max_sensors]hwmon.Sensor = undefined,
    sensor_count: usize = 0,
    text: [max_text]u8 = undefined,
    text_len: usize = 0,
    ok: bool = true,

    fn at(self: *const Source, index: usize) *const Sample {
        return &self.ring[(self.start + index) % max_samples];
    }

    /// Append a sample and forget those older than the retention window.
    fn push(self: *Source, sample: Sample) void {
        if (self.len == max_samples) {
            self.start = (self.start + 1) % max_samples;
            self.len -= 1;
        }
        self.ring[(self.start + self.len) % max_samples] = sample;
        self.len += 1;
        const oldest = sample.t - @as(f64, @floatFromInt(self.keep_ms));
        while (self.len > 1 and self.at(0).t < oldest) {
            self.start = (self.start + 1) % max_samples;
            self.len -= 1;
        }
        self.revision +%= 1;
    }

    fn clear(self: *Source) void {
        self.start = 0;
        self.len = 0;
        self.revision +%= 1;
    }
};

pub const Wake = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque) void,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    origin: std.Io.Timestamp,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    sources: []Source,
    wake: ?Wake = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, origin: std.Io.Timestamp, specs: []const Spec) !*Service {
        if (specs.len > max_sources) return error.TooManySources;
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        const sources = try allocator.alloc(Source, specs.len);
        var created: usize = 0;
        errdefer {
            for (sources[0..created]) |*source| freeSource(allocator, source);
            allocator.free(sources);
        }
        for (specs, sources) |spec, *source| {
            const name = try allocator.dupe(u8, spec.name);
            errdefer allocator.free(name);
            const argv = try allocator.alloc([]u8, spec.argv.len);
            var copied: usize = 0;
            errdefer {
                for (argv[0..copied]) |arg| allocator.free(arg);
                allocator.free(argv);
            }
            for (spec.argv, argv) |arg, *destination| {
                destination.* = try allocator.dupe(u8, arg);
                copied += 1;
            }
            source.* = .{
                .name = name,
                .kind = spec.kind,
                .every_ms = @max(50, spec.every_ms),
                .keep_ms = spec.keep_ms,
                .argv = argv,
            };
            created += 1;
        }
        self.* = .{ .allocator = allocator, .io = io, .origin = origin, .sources = sources };
        errdefer self.group.cancel(io);
        for (0..sources.len) |index| try self.group.concurrent(io, run, .{ self, index });
        return self;
    }

    pub fn deinit(self: *Service) void {
        self.group.cancel(self.io);
        const allocator = self.allocator;
        for (self.sources) |*source| freeSource(allocator, source);
        allocator.free(self.sources);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn freeSource(allocator: std.mem.Allocator, source: *Source) void {
        for (source.argv) |arg| allocator.free(arg);
        allocator.free(source.argv);
        allocator.free(source.name);
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

    pub fn sourceCount(self: *const Service) usize {
        return self.sources.len;
    }

    pub fn sourceName(self: *const Service, index: usize) []const u8 {
        return self.sources[index].name;
    }

    /// Source `index`'s revision, which changes whenever its data does.
    pub fn revision(self: *Service, index: usize) u64 {
        self.lock();
        defer self.unlock();
        return self.sources[index].revision;
    }

    /// Source `index` as a script value (see `encodeSource`), allocated in
    /// `arena`, and its revision.
    pub fn encode(self: *Service, comptime Value: type, arena: std.mem.Allocator, index: usize) !struct { revision: u64, value: Value } {
        self.lock();
        defer self.unlock();
        const source = &self.sources[index];
        return .{ .revision = source.revision, .value = try encodeSource(Value, arena, source) };
    }

    fn lock(self: *Service) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Service) void {
        self.mutex.unlock(self.io);
    }

    fn now(self: *const Service) f64 {
        const elapsed = self.origin.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds;
        return @as(f64, @floatFromInt(@max(elapsed, 0))) / std.time.ns_per_ms;
    }

    /// Record a change made under the lock and tell the consumer.
    fn publish(self: *Service) void {
        const wake = self.wake;
        self.unlock();
        if (wake) |callback| callback.run(callback.context);
    }

    fn run(self: *Service, index: usize) std.Io.Cancelable!void {
        const source = &self.sources[index];
        var state: TaskState = .{};
        while (true) {
            self.collect(source, &state) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
            // A listener only returns when its program ended or never started.
            const pause = if (listens(source.kind)) @max(source.every_ms, restart_ms) else source.every_ms;
            try std.Io.sleep(self.io, .fromMilliseconds(pause), .awake);
        }
    }

    fn listens(kind: Kind) bool {
        return kind == .audio or kind == .gpu;
    }

    /// What a source's task carries between samples.
    const TaskState = struct {
        cpu: ?collectors.CpuRead = null,
        interface: [64]u8 = undefined,
        interface_len: usize = 0,
        addresses_ms: ?f64 = null,
        disks_found_ms: ?f64 = null,
    };

    fn collect(self: *Service, source: *Source, state: *TaskState) !void {
        switch (source.kind) {
            .cpu => {
                const current = try collectors.readCpu(self.io);
                defer state.cpu = current;
                const previous = state.cpu orelse return;
                var sample = Sample{ .t = self.now() };
                var cores = [_]f32{0} ** collectors.max_cpu_count;
                const count = @min(previous.count, current.count);
                for (0..count) |core| {
                    const busy = collectors.utilization(previous.cores[core], current.cores[core]);
                    cores[core] = @floatCast(busy * 100);
                    sample.fields[0] += busy;
                }
                sample.fields[1] = collectors.utilization(previous.aggregate, current.aggregate) * 100;
                const frequency = collectors.readCpuFrequency(self.io, count);
                sample.fields[2] = frequency.average_mhz;
                sample.fields[3] = frequency.max_mhz;
                self.lock();
                source.cpu_count = @intCast(count);
                source.cpu_cores = cores;
                source.push(sample);
                self.publish();
            },
            .memory => {
                const memory = try collectors.readMemory(self.io);
                var sample = Sample{ .t = self.now() };
                inline for (.{ "total", "used", "cache", "arc", "free", "swap_total", "swap_used", "zswap_stored", "zswap_compressed" }, 0..) |name, field|
                    sample.fields[field] = @floatFromInt(@field(memory, name));
                self.lock();
                source.push(sample);
                self.publish();
            },
            .network => {
                if (state.interface_len == 0) {
                    const name = collectors.readDefaultInterface(self.io, &state.interface) catch return;
                    state.interface_len = name.len;
                }
                const counters = (collectors.readNetwork(self.io, state.interface[0..state.interface_len]) catch null) orelse {
                    // The interface went away; look for the default route again.
                    state.interface_len = 0;
                    return;
                };
                var sample = Sample{ .t = self.now() };
                sample.fields[0] = @floatFromInt(counters.rx);
                sample.fields[1] = @floatFromInt(counters.tx);
                const look = state.addresses_ms == null or sample.t - state.addresses_ms.? >= address_ms;
                var address: addresses.Address = undefined;
                var address6: addresses.Address = undefined;
                var tunnels: [addresses.max_tunnels]addresses.Address = undefined;
                var tunnel_count: usize = 0;
                if (look) {
                    state.addresses_ms = sample.t;
                    address = addresses.read(state.interface[0..state.interface_len]);
                    address6 = addresses.readIpv6(self.io, state.interface[0..state.interface_len]);
                    tunnel_count = addresses.tunnels(self.io, &tunnels);
                }
                self.lock();
                if (look) {
                    source.address = address;
                    source.address6 = address6;
                    source.tunnels = tunnels;
                    source.tunnel_count = tunnel_count;
                }
                const renamed = !std.mem.eql(u8, source.interface[0..source.interface_len], state.interface[0..state.interface_len]);
                if (renamed) {
                    // Another interface's counters do not continue this one's.
                    source.clear();
                    @memcpy(source.interface[0..state.interface_len], state.interface[0..state.interface_len]);
                    source.interface_len = state.interface_len;
                }
                source.push(sample);
                self.publish();
            },
            .disks => {
                const at = self.now();
                if (state.disks_found_ms == null or at - state.disks_found_ms.? >= disk_discovery_ms) {
                    var disks: [max_disks]collectors.Disk = undefined;
                    const count = try collectors.discoverDisks(self.allocator, self.io, &disks);
                    state.disks_found_ms = at;
                    self.lock();
                    const same = count == source.disk_count and (for (disks[0..count], source.disks[0..count]) |*a, *b| {
                        if (!std.mem.eql(u8, a.group.keySlice(), b.group.keySlice())) break false;
                    } else true);
                    // Sizes change in place; a different set of disks starts afresh.
                    if (!same) source.clear();
                    source.disks = disks;
                    source.disk_count = count;
                    source.revision +%= 1;
                    self.publish();
                }
                self.lock();
                const count = source.disk_count;
                const targets = source.disks;
                self.unlock();
                var sample = Sample{ .t = self.now() };
                var buffer: [64 * 1024]u8 = undefined;
                const diskstats = try collectors.readDiskstats(self.io, &buffer);
                for (targets[0..count], 0..) |*disk, index| {
                    const counters = collectors.diskCounters(diskstats, disk) orelse continue;
                    sample.fields[index * 2] = @floatFromInt(counters.read);
                    sample.fields[index * 2 + 1] = @floatFromInt(counters.written);
                }
                self.lock();
                if (source.disk_count == count) source.push(sample);
                self.publish();
            },
            .sensors => {
                const at = self.now();
                if (state.disks_found_ms == null or at - state.disks_found_ms.? >= disk_discovery_ms) {
                    var sensors: [max_sensors]hwmon.Sensor = undefined;
                    const count = hwmon.discover(self.io, &sensors);
                    state.disks_found_ms = at;
                    self.lock();
                    const same = count == source.sensor_count and (for (sensors[0..count], source.sensors[0..count]) |*a, *b| {
                        if (!std.mem.eql(u8, a.inputSlice(), b.inputSlice())) break false;
                    } else true);
                    if (!same) source.clear();
                    source.sensors = sensors;
                    source.sensor_count = count;
                    source.revision +%= 1;
                    self.publish();
                }
                self.lock();
                const count = source.sensor_count;
                const sensors = source.sensors;
                self.unlock();
                var sample = Sample{ .t = self.now() };
                for (sensors[0..count], 0..) |*sensor, index| sample.fields[index] = hwmon.read(self.io, sensor) orelse 0;
                self.lock();
                if (source.sensor_count == count) source.push(sample);
                self.publish();
            },
            .gpu => {
                var period: [24]u8 = undefined;
                const every = std.fmt.bufPrint(&period, "--loop-ms={d}", .{source.every_ms}) catch unreachable;
                var listener = GpuListener{ .service = self, .source = source };
                try stream.lines(self.io, &.{
                    "nvidia-smi",
                    "--id=0",
                    "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw",
                    "--format=csv,noheader,nounits",
                    every,
                }, &listener);
            },
            .audio => {
                // Read once, then again whenever a sink or the default sink
                // changes.
                var listener = AudioListener{ .service = self, .source = source };
                try listener.read();
                try stream.lines(self.io, &.{ "pactl", "subscribe" }, &listener);
            },
            .battery => {
                const battery = try collectors.readBattery(self.io);
                var sample = Sample{ .t = self.now() };
                sample.fields[0] = @floatFromInt(@intFromBool(battery.present));
                sample.fields[1] = @floatFromInt(battery.percent);
                sample.fields[2] = @floatFromInt(@intFromBool(battery.charging));
                sample.fields[3] = @floatFromInt(@intFromBool(battery.on_ac));
                self.lock();
                source.push(sample);
                self.publish();
            },
            .command => {
                if (source.argv.len == 0) return;
                const argv = try self.allocator.alloc([]const u8, source.argv.len);
                defer self.allocator.free(argv);
                for (source.argv, argv) |arg, *destination| destination.* = arg;
                const output = collectors.command(self.allocator, self.io, argv);
                defer if (output) |bytes| self.allocator.free(bytes) else |_| {};
                const text = if (output) |bytes| std.mem.trim(u8, bytes, " \t\r\n") else |_| "";
                self.lock();
                const length = @min(text.len, max_text);
                @memcpy(source.text[0..length], text[0..length]);
                source.text_len = length;
                source.ok = if (output) |_| true else |_| false;
                source.push(.{ .t = self.now() });
                self.publish();
            },
        }
    }
};

const AudioListener = struct {
    service: *Service,
    source: *Source,

    fn read(self: *AudioListener) !void {
        const service = self.service;
        const volume = try collectors.command(service.allocator, service.io, &.{ "pactl", "get-sink-volume", "@DEFAULT_SINK@" });
        defer service.allocator.free(volume);
        const mute = try collectors.command(service.allocator, service.io, &.{ "pactl", "get-sink-mute", "@DEFAULT_SINK@" });
        defer service.allocator.free(mute);
        const percent = collectors.parsePactlVolume(volume) orelse return;
        var sample = Sample{ .t = service.now() };
        sample.fields[0] = @floatFromInt(percent);
        sample.fields[1] = @floatFromInt(@intFromBool(collectors.parsePactlMute(mute)));
        service.lock();
        self.source.push(sample);
        service.publish();
    }

    /// `Event 'change' on sink #56`; `on server` when the default changes.
    /// Streams (sink-input) and sources do not move the sink's volume.
    pub fn line(self: *AudioListener, text: []const u8) !void {
        if (std.mem.indexOf(u8, text, " on sink #") == null and std.mem.indexOf(u8, text, " on server") == null) return;
        self.read() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }
};

const GpuListener = struct {
    service: *Service,
    source: *Source,

    pub fn line(self: *GpuListener, text: []const u8) !void {
        const gpu = collectors.parseGpu(text) orelse return;
        var sample = Sample{ .t = self.service.now() };
        sample.fields[0] = gpu.busy;
        sample.fields[1] = gpu.temperature;
        sample.fields[2] = gpu.memory_used;
        sample.fields[3] = gpu.memory_total;
        sample.fields[4] = gpu.power;
        self.service.lock();
        self.source.push(sample);
        self.service.publish();
    }
};

/// One source as a script value: an object holding `t` (sample times) and a
/// series per field, plus each kind's latest non-series state:
///   cpu      busy (cores' worth), percent, mhz (average clock), mhz_max;
///            count, cores (latest % per core)
///   memory   total, used, cache, arc, free, swap_*, zswap_* (bytes)
///   network  rx, tx (cumulative bytes); interface, address (its IPv4, or
///            empty), address6 (its stable global IPv6, or empty), tunnels =
///            { { interface, address } } (WireGuard, tun)
///   disks    disks = { { label, total, used, avail, read, write, devices,
///            state, data_errors } } where read and write are cumulative-bytes
///            series against the shared `t`, devices the kernel names of the
///            block devices it is on, state a pool's health (else empty)
///   sensors  sensors = { { label, kind, critical, temperature } }: kind is
///            cpu, gpu or drive (labelled by kernel name, e.g. nvme0), critical
///            the chip's limit in °C (0 if none), temperature a °C series
///   gpu      busy (%), temperature (°C), memory_used, memory_total (bytes),
///            power (W)
///   audio    percent, muted (0/1)
///   battery  present, percent, charging, on_ac (0/1)
///   command  text (latest output, trimmed), ok
/// `Value` is the consumer's script value type (it needs number, string,
/// boolean, array and object variants), so this module needs no script layer.
fn encodeSource(comptime Value: type, arena: std.mem.Allocator, source: *const Source) !Value {
    var fields = std.ArrayList(Value.Field).empty;
    const times = try arena.alloc(Value, source.len);
    for (times, 0..) |*item, index| item.* = .{ .number = source.at(index).t };
    try fields.append(arena, .{ .key = "t", .value = .{ .array = times } });
    for (fieldNames(source.kind), 0..) |name, field| {
        try fields.append(arena, .{ .key = name, .value = try series(Value, arena, source, field) });
    }
    switch (source.kind) {
        .cpu => {
            const cores = try arena.alloc(Value, source.cpu_count);
            for (cores, 0..) |*item, index| item.* = .{ .number = source.cpu_cores[index] };
            try fields.append(arena, .{ .key = "count", .value = .{ .number = @floatFromInt(source.cpu_count) } });
            try fields.append(arena, .{ .key = "cores", .value = .{ .array = cores } });
        },
        .network => {
            try fields.append(arena, .{ .key = "interface", .value = .{ .string = try arena.dupe(u8, source.interface[0..source.interface_len]) } });
            try fields.append(arena, .{ .key = "address", .value = .{ .string = try arena.dupe(u8, source.address.textSlice()) } });
            try fields.append(arena, .{ .key = "address6", .value = .{ .string = try arena.dupe(u8, source.address6.textSlice()) } });
            const tunnels = try arena.alloc(Value, source.tunnel_count);
            for (tunnels, source.tunnels[0..source.tunnel_count]) |*item, *tunnel| item.* = .{ .object = try arena.dupe(Value.Field, &.{
                .{ .key = "interface", .value = .{ .string = try arena.dupe(u8, tunnel.interfaceSlice()) } },
                .{ .key = "address", .value = .{ .string = try arena.dupe(u8, tunnel.textSlice()) } },
            }) };
            try fields.append(arena, .{ .key = "tunnels", .value = .{ .array = tunnels } });
        },
        .sensors => {
            const sensors = try arena.alloc(Value, source.sensor_count);
            for (sensors, source.sensors[0..source.sensor_count], 0..) |*item, *sensor, index| item.* = .{ .object = try arena.dupe(Value.Field, &.{
                .{ .key = "label", .value = .{ .string = try arena.dupe(u8, sensor.labelSlice()) } },
                .{ .key = "kind", .value = .{ .string = @tagName(sensor.kind) } },
                .{ .key = "critical", .value = .{ .number = sensor.critical } },
                .{ .key = "temperature", .value = try series(Value, arena, source, index) },
            }) };
            try fields.append(arena, .{ .key = "sensors", .value = .{ .array = sensors } });
        },
        .disks => {
            const disks = try arena.alloc(Value, source.disk_count);
            for (disks, source.disks[0..source.disk_count], 0..) |*item, *disk, index| {
                const group = disk.group;
                const devices = try arena.alloc(Value, disk.device_count);
                for (devices, disk.deviceSlice()) |*name, *device| name.* = .{ .string = try arena.dupe(u8, device.slice()) };
                const entry = try arena.dupe(Value.Field, &.{
                    .{ .key = "label", .value = .{ .string = try arena.dupe(u8, group.labelSlice()) } },
                    .{ .key = "total", .value = .{ .number = @floatFromInt(group.total) } },
                    .{ .key = "used", .value = .{ .number = @floatFromInt(group.used) } },
                    .{ .key = "avail", .value = .{ .number = @floatFromInt(group.avail) } },
                    .{ .key = "read", .value = try series(Value, arena, source, index * 2) },
                    .{ .key = "write", .value = try series(Value, arena, source, index * 2 + 1) },
                    .{ .key = "devices", .value = .{ .array = devices } },
                    .{ .key = "state", .value = .{ .string = try arena.dupe(u8, disk.stateSlice()) } },
                    .{ .key = "data_errors", .value = .{ .number = @floatFromInt(disk.data_errors) } },
                });
                item.* = .{ .object = entry };
            }
            try fields.append(arena, .{ .key = "disks", .value = .{ .array = disks } });
        },
        .command => {
            try fields.append(arena, .{ .key = "text", .value = .{ .string = try arena.dupe(u8, source.text[0..source.text_len]) } });
            try fields.append(arena, .{ .key = "ok", .value = .{ .boolean = source.ok } });
        },
        .memory, .gpu, .audio, .battery => {},
    }
    return .{ .object = try fields.toOwnedSlice(arena) };
}

fn series(comptime Value: type, arena: std.mem.Allocator, source: *const Source, field: usize) !Value {
    const values = try arena.alloc(Value, source.len);
    for (values, 0..) |*item, index| item.* = .{ .number = source.at(index).fields[field] };
    return .{ .array = values };
}

const TestValue = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const TestValue,
    object: []const Field,

    const Field = struct { key: []const u8, value: TestValue };

    fn get(self: TestValue, key: []const u8) ?TestValue {
        for (self.object) |field| if (std.mem.eql(u8, field.key, key)) return field.value;
        return null;
    }
};

fn testSource(kind: Kind, keep_ms: u32) Source {
    return .{ .name = @constCast("test"), .kind = kind, .every_ms = 100, .keep_ms = keep_ms, .argv = &.{} };
}

test "a source keeps samples for its retention window, oldest first" {
    var source = testSource(.network, 1000);
    for (0..30) |step| source.push(.{ .t = @floatFromInt(step * 100), .fields = .{ @floatFromInt(step), 0, 0, 0, 0, 0, 0, 0, 0, 0 } });
    // Newest at 2900: samples back to 1900 are kept.
    try std.testing.expectEqual(@as(usize, 11), source.len);
    try std.testing.expectEqual(@as(f64, 1900), source.at(0).t);
    try std.testing.expectEqual(@as(f64, 29), source.at(10).fields[0]);
}

test "sources encode as timestamped series with named fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var source = testSource(.network, 10_000);
    source.push(.{ .t = 100, .fields = .{ 1000, 50, 0, 0, 0, 0, 0, 0, 0, 0 } });
    source.push(.{ .t = 600, .fields = .{ 3000, 70, 0, 0, 0, 0, 0, 0, 0, 0 } });
    @memcpy(source.interface[0..4], "eth0");
    source.interface_len = 4;
    const value = try encodeSource(TestValue, arena_state.allocator(), &source);
    try std.testing.expectEqual(@as(f64, 600), value.get("t").?.array[1].number);
    try std.testing.expectEqual(@as(f64, 3000), value.get("rx").?.array[1].number);
    try std.testing.expectEqual(@as(f64, 50), value.get("tx").?.array[0].number);
    try std.testing.expectEqualStrings("eth0", value.get("interface").?.string);
}

test {
    _ = collectors;
    _ = hwmon;
    _ = addresses;
}
