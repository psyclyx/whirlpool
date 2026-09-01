//! River XKB binding ownership for a loaded Whirlpool program.

const std = @import("std");
const wayland = @import("wayland");
const client_transport = @import("whirlpool-wayland-client");
const script = @import("whirlpool-script");

const Binding = script.config.Binding;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    bindings: []const Binding,
    xkb: ?*wayland.client.river.XkbBindingsV1 = null,
    xkb_version: u32 = 0,
    seats: std.ArrayList(SeatEntry) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    pending_actions: std.ArrayList(usize) = .empty,
    desired_mode: []const u8 = script.config.default_mode,
    mode_change_pending: bool = true,
    listener_error: ?anyerror = null,

    const Entry = struct {
        proxy: *wayland.client.river.XkbBindingV1,
        action_index: usize,
        enabled: bool = false,
    };

    const SeatEntry = struct {
        proxy: *wayland.client.river.XkbBindingsSeatV1,
        armed: bool = false,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        client: *client_transport.Client,
        config: *const script.config.Config,
    ) !Runtime {
        // Borrow the owned binding allocation, not the address of Config
        // itself. Services.init returns its Config by value, so retaining that
        // temporary struct address would dangle before the first seat event.
        var result: Runtime = .{ .allocator = allocator, .bindings = config.bindings };
        errdefer result.deinit();
        if (config.bindings.len == 0) return result;
        for (config.bindings) |binding| switch (binding.action) {
            .enter_mode => |target| {
                var found = std.mem.eql(u8, target, script.config.default_mode);
                for (config.bindings) |candidate| {
                    if (std.mem.eql(u8, candidate.mode, target)) found = true;
                }
                if (!found) return error.UnknownBindingMode;
            },
            else => {},
        };

        // Reuse the initial registry snapshot. A roundtrip here, after the
        // River manager listener exists but before manager hooks are wired,
        // can consume the initial seat event before bindings can be created.
        const globals = if (client.globals.items.len != 0)
            client.globals.items
        else
            try client.enumerateGlobals();
        for (globals) |global| {
            if (!std.mem.eql(u8, global.interface, "river_xkb_bindings_v1")) continue;
            result.xkb_version = @min(global.version, 3);
            result.xkb = try client.registry.bind(
                global.name,
                wayland.client.river.XkbBindingsV1,
                result.xkb_version,
            );
            std.log.info("River XKB bindings bound (global {d}, {d} entries)", .{ global.name, config.bindings.len });
            return result;
        }
        return error.MissingXkbBindingsGlobal;
    }

    pub fn deinit(self: *Runtime) void {
        for (self.entries.items) |entry| entry.proxy.destroy();
        self.entries.deinit(self.allocator);
        for (self.seats.items) |seat| seat.proxy.destroy();
        self.seats.deinit(self.allocator);
        self.pending_actions.deinit(self.allocator);
        if (self.xkb) |proxy| proxy.destroy();
        self.* = undefined;
    }

    /// Called after River announces a seat. Binding creation is safe here;
    /// enable requests are deliberately deferred to the next manage phase.
    pub fn onSeat(self: *Runtime, seat: *wayland.client.river.SeatV1) !void {
        const xkb = self.xkb orelse {
            std.log.err("River seat arrived before XKB bindings global was bound", .{});
            return error.MissingXkbBindingsGlobal;
        };
        if (self.xkb_version >= 2) {
            const mode_seat = try xkb.getSeat(seat);
            errdefer mode_seat.destroy();
            mode_seat.setListener(*Runtime, onSeatModeEvent, self);
            try self.seats.append(self.allocator, .{ .proxy = mode_seat });
        }
        for (self.bindings, 0..) |binding, action_index| {
            const modifiers: wayland.client.river.SeatV1.Modifiers = @bitCast(binding.modifiers);
            const proxy = try xkb.getXkbBinding(seat, binding.keysym, modifiers);
            errdefer proxy.destroy();
            proxy.setListener(*Runtime, onBindingEvent, self);
            try self.entries.append(self.allocator, .{ .proxy = proxy, .action_index = action_index });
        }
    }

    /// River requires binding enable/disable requests to occur in a manage
    /// sequence. The host calls this from its manage-start hook.
    pub fn applyPendingMode(self: *Runtime) !void {
        var changed: usize = 0;
        for (self.entries.items) |*entry| {
            const should_enable = std.mem.eql(u8, self.bindings[entry.action_index].mode, self.desired_mode);
            if (should_enable == entry.enabled) continue;
            if (should_enable) entry.proxy.enable() else entry.proxy.disable();
            entry.enabled = should_enable;
            changed += 1;
        }
        const one_shot = !std.mem.eql(u8, self.desired_mode, script.config.default_mode);
        for (self.seats.items) |*seat| {
            if (seat.armed == one_shot) continue;
            if (one_shot) seat.proxy.ensureNextKeyEaten() else seat.proxy.cancelEnsureNextKeyEaten();
            seat.armed = one_shot;
        }
        self.mode_change_pending = false;
        if (changed != 0)
            std.log.debug("Switched River XKB bindings to mode '{s}' ({d} changes)", .{ self.desired_mode, changed });
    }

    pub fn hasPendingModeChange(self: *const Runtime) bool {
        return self.mode_change_pending;
    }

    pub fn takeActions(self: *Runtime) ![]usize {
        if (self.listener_error) |err| return err;
        return self.pending_actions.toOwnedSlice(self.allocator);
    }

    fn stageBinding(self: *Runtime, action_index: usize) !void {
        if (action_index >= self.bindings.len) return error.UnknownBinding;
        const configured = self.bindings[action_index];
        if (!std.mem.eql(u8, configured.mode, self.desired_mode)) return;
        switch (configured.action) {
            .enter_mode => |target| {
                self.desired_mode = target;
                self.mode_change_pending = true;
                return;
            },
            else => {},
        }
        try self.pending_actions.append(self.allocator, action_index);
        if (!std.mem.eql(u8, configured.mode, script.config.default_mode)) {
            self.desired_mode = script.config.default_mode;
            self.mode_change_pending = true;
        }
    }

    fn onBindingEvent(
        binding: *wayland.client.river.XkbBindingV1,
        event: wayland.client.river.XkbBindingV1.Event,
        raw: *Runtime,
    ) void {
        switch (event) {
            .pressed => {
                const action_index = findAction(raw, binding);
                if (action_index == std.math.maxInt(usize)) return;
                raw.stageBinding(action_index) catch |err| {
                    raw.listener_error = err;
                };
            },
            .released, .stop_repeat => {},
        }
    }

    fn onSeatModeEvent(
        seat_proxy: *wayland.client.river.XkbBindingsSeatV1,
        event: wayland.client.river.XkbBindingsSeatV1.Event,
        raw: *Runtime,
    ) void {
        switch (event) {
            .ate_unbound_key => {
                for (raw.seats.items) |*seat| {
                    if (seat.proxy == seat_proxy) seat.armed = false;
                }
                raw.desired_mode = script.config.default_mode;
                raw.mode_change_pending = true;
            },
            .modifiers_update => {},
        }
    }

    fn findAction(self: *const Runtime, proxy: *wayland.client.river.XkbBindingV1) usize {
        for (self.entries.items) |entry| if (entry.proxy == proxy) return entry.action_index;
        return std.math.maxInt(usize);
    }
};

test "keybinding runtime keeps the config/action boundary typed" {
    try std.testing.expect(@sizeOf(Runtime) > 0);
    _ = Binding;
}

test "one-shot modes capture one action and return to default" {
    const bindings = [_]Binding{
        .{
            .key = @constCast("m"),
            .mode = @constCast(script.config.default_mode),
            .keysym = 'm',
            .modifiers = 8,
            .action = .{ .enter_mode = @constCast("mark") },
        },
        .{
            .key = @constCast("a"),
            .mode = @constCast("mark"),
            .keysym = 'a',
            .modifiers = 0,
            .action = .{ .layout = .{ .name = @constCast("mark"), .args = @constCast(&[_][]u8{}) } },
        },
        .{
            .key = @constCast("a"),
            .mode = @constCast("clear-mark"),
            .keysym = 'a',
            .modifiers = 0,
            .action = .{ .layout = .{ .name = @constCast("clear-mark"), .args = @constCast(&[_][]u8{}) } },
        },
    };
    var runtime: Runtime = .{ .allocator = std.testing.allocator, .bindings = &bindings };
    defer runtime.pending_actions.deinit(std.testing.allocator);

    try runtime.stageBinding(0);
    try std.testing.expectEqualStrings("mark", runtime.desired_mode);
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_actions.items.len);
    try runtime.stageBinding(2);
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_actions.items.len);
    try runtime.stageBinding(1);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_actions.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_actions.items[0]);
    try std.testing.expectEqualStrings(script.config.default_mode, runtime.desired_mode);
}
