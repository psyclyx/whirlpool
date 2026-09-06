//! Portable layer-shell application startup.

const std = @import("std");
const wayland = @import("wayland");
const script = @import("whirlpool-script");
const wayland_client = @import("whirlpool-wayland-client");
const wayland_runtime = @import("whirlpool-wayland-runtime");
const layer_shell_runtime = @import("whirlpool-wayland-layer-shell-runtime");
const status_app = @import("whirlpool-app-status");

const frame_interval_ms: f64 = 16;

pub fn run(allocator: std.mem.Allocator, io: std.Io, config_path: ?[]const u8) !void {
    const path = config_path orelse return error.MissingConfig;
    var config = try script.config.load(allocator, io, path);
    defer config.deinit();
    const surface = config.surface("layer-shell", "shell") orelse
        return error.MissingLayerShellSurface;
    const bottom = std.mem.eql(u8, surface.edge, "bottom");
    const surface_height = if (surface.height != 0) surface.height else 40;
    const exclusive_zone: i32 = @intCast(if (surface.exclusive_zone != 0) surface.exclusive_zone else surface_height);

    var client = try wayland_client.Client.connect(allocator);
    defer client.deinit();
    const compositor = try bindCompositor(client);
    defer compositor.destroy();

    var layer = try layer_shell_runtime.Runtime.init(allocator, io, client, compositor, .{
        .height = surface_height,
        .anchor = .{ .top = !bottom, .bottom = bottom, .left = true, .right = true },
        .exclusive_zone = exclusive_zone,
    }, surface);

    var session: wayland_runtime.Session = undefined;
    try session.init(client);
    defer session.deinit();
    const status = try status_app.Service.init(allocator, io);
    defer status.deinit();
    var layer_live = true;
    // This CLI owns the whole client connection. On any process-exit path,
    // stop its worker and drop local proxies before wl_display disconnects.
    defer if (layer_live) layer.abandon();
    session.setPollInterval(16);
    layer.setWake(.{ .context = @ptrCast(&session), .run = wakeSession });
    status.setWake(.{ .context = @ptrCast(&session), .run = wakeSession });
    defer status.clearWake();
    var after_dispatch = AfterDispatch{
        .runtime = &layer,
        .session = &session,
        .status = status,
        .io = io,
        .clock_origin = std.Io.Clock.awake.now(io),
    };
    session.setAfterDispatch(.{ .context = @ptrCast(&after_dispatch), .run = AfterDispatch.run });
    std.log.info("Portable layer-shell host connected", .{});
    session.run() catch |err| switch (err) {
        error.Disconnected => {
            std.log.info("Wayland display disconnected", .{});
            layer.abandon();
            layer_live = false;
        },
        else => return err,
    };
}

fn wakeSession(raw: ?*anyopaque) void {
    const session: *wayland_runtime.Session = @ptrCast(@alignCast(raw orelse return));
    session.loop.wake() catch {};
}

const AfterDispatch = struct {
    runtime: *layer_shell_runtime.Runtime,
    session: *wayland_runtime.Session,
    status: *status_app.Service,
    io: std.Io,
    clock_origin: std.Io.Timestamp,
    status_revision: u64 = 0,
    last_frame_ms: ?f64 = null,

    fn run(raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return error.InvalidContext));
        if (self.status.latestAfter(self.status_revision)) |latest| {
            self.status_revision = latest.revision;
            var cpu_history: [status_app.cpu_history_len]script.program_loader.Value = undefined;
            var cpu_cores: [status_app.max_cpu_count]script.program_loader.Value = undefined;
            var rx_history: [status_app.network_history_len]script.program_loader.Value = undefined;
            var tx_history: [status_app.network_history_len]script.program_loader.Value = undefined;
            for (0..status_app.cpu_history_len) |index|
                cpu_history[index] = .{ .number = latest.value.cpu_history[index] };
            const cpu_core_count: usize = latest.value.cpu_core_count;
            for (0..cpu_core_count) |index|
                cpu_cores[index] = .{ .number = latest.value.cpu_cores[index] };
            for (0..status_app.network_history_len) |index| {
                rx_history[index] = .{ .number = latest.value.network_rx_history[index] };
                tx_history[index] = .{ .number = latest.value.network_tx_history[index] };
            }
            const values = [_]script.program_loader.Value{
                .{ .string = &latest.value.time },
                .{ .string = &latest.value.dow },
                .{ .string = &latest.value.date },
                .{ .number = @floatFromInt(latest.value.cpu_percent) },
                .{ .array = &cpu_history },
                .{ .number = @floatFromInt(latest.value.memory_percent) },
                .{ .number = @floatFromInt(latest.value.disk_percent) },
                .{ .number = latest.value.network_rx },
                .{ .number = latest.value.network_tx },
                .{ .array = &rx_history },
                .{ .array = &tx_history },
                .{ .number = @floatFromInt(latest.value.audio_percent) },
                .{ .boolean = latest.value.audio_muted },
                .{ .boolean = latest.value.audio_visible },
                .{ .boolean = latest.value.battery_present },
                .{ .number = @floatFromInt(latest.value.battery_percent) },
                .{ .boolean = latest.value.battery_charging },
                .{ .number = @floatFromInt(latest.value.network_sample_sequence) },
                .{ .number = @floatFromInt(latest.value.cpu_core_count) },
                .{ .number = latest.value.cpu_core_equivalents },
                .{ .array = cpu_cores[0..cpu_core_count] },
                .{ .number = @floatFromInt(latest.value.cpu_sample_sequence) },
                .{ .number = latest.value.network_capacity },
            };
            try self.runtime.update(.{ .service = "status", .values = &values });
        }
        const elapsed = self.clock_origin.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds;
        const now_ms = @as(f64, @floatFromInt(@max(elapsed, 0))) / 1_000_000.0;
        if (frameDue(self.last_frame_ms, now_ms)) {
            self.last_frame_ms = now_ms;
            try self.runtime.frame(now_ms);
        }
        _ = self.runtime.presentIfReady() catch |err| switch (err) {
            error.NotReady => return,
            error.SurfaceClosed => {
                try self.session.requestStop();
                return;
            },
            else => return err,
        };
    }
};

fn frameDue(last_frame_ms: ?f64, now_ms: f64) bool {
    const last = last_frame_ms orelse return true;
    return now_ms - last >= frame_interval_ms;
}

fn bindCompositor(client: *wayland_client.Client) !*wayland.client.wl.Compositor {
    const globals = try client.enumerateGlobals();
    for (globals) |global| if (std.mem.eql(u8, global.interface, "wl_compositor")) {
        return client.registry.bind(global.name, wayland.client.wl.Compositor, @min(global.version, 6)) catch return error.BindFailed;
    };
    return error.MissingCompositor;
}
