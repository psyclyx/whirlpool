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
    entries: std.ArrayList(Entry) = .empty,
    pending_actions: std.ArrayList(usize) = .empty,
    listener_error: ?anyerror = null,

    const Entry = struct {
        proxy: *wayland.client.river.XkbBindingV1,
        action_index: usize,
        enabled: bool = false,
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

        // Reuse the initial registry snapshot. A roundtrip here, after the
        // River manager listener exists but before manager hooks are wired,
        // can consume the initial seat event before bindings can be created.
        const globals = if (client.globals.items.len != 0)
            client.globals.items
        else
            try client.enumerateGlobals();
        for (globals) |global| {
            if (!std.mem.eql(u8, global.interface, "river_xkb_bindings_v1")) continue;
            result.xkb = try client.registry.bind(
                global.name,
                wayland.client.river.XkbBindingsV1,
                @min(global.version, 1),
            );
            std.log.info("River XKB bindings bound (global {d}, {d} entries)", .{ global.name, config.bindings.len });
            return result;
        }
        return error.MissingXkbBindingsGlobal;
    }

    pub fn deinit(self: *Runtime) void {
        for (self.entries.items) |entry| entry.proxy.destroy();
        self.entries.deinit(self.allocator);
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
    pub fn enablePending(self: *Runtime) !void {
        std.log.info("Enabling {d} River XKB bindings", .{self.entries.items.len});
        for (self.entries.items) |*entry| if (!entry.enabled) {
            entry.proxy.enable();
            entry.enabled = true;
        };
    }

    pub fn takeActions(self: *Runtime) ![]usize {
        if (self.listener_error) |err| return err;
        return self.pending_actions.toOwnedSlice(self.allocator);
    }

    fn onBindingEvent(
        binding: *wayland.client.river.XkbBindingV1,
        event: wayland.client.river.XkbBindingV1.Event,
        raw: *Runtime,
    ) void {
        switch (event) {
            .pressed => {
                raw.pending_actions.append(raw.allocator, findAction(raw, binding)) catch |err| {
                    raw.listener_error = err;
                };
            },
            .released => {},
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
