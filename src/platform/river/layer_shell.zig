//! River window-manager integration for `river_layer_shell_v1`.
//!
//! One child is paired with every River output and seat. Child records are
//! heap-owned because Wayland retains their addresses as listener contexts.

const std = @import("std");
const wayland = @import("wayland");
const client_api = @import("whirlpool-wayland-client");

pub const Area = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Focus = enum { exclusive, non_exclusive, none };

pub const Hooks = struct {
    context: ?*anyopaque = null,
    on_area: ?*const fn (?*anyopaque, *wayland.client.river.OutputV1, Area) void = null,
    on_focus: ?*const fn (?*anyopaque, *wayland.client.river.SeatV1, Focus) void = null,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    proxy: *wayland.client.river.LayerShellV1,
    outputs: std.ArrayList(*Output) = .empty,
    seats: std.ArrayList(*Seat) = .empty,
    hooks: Hooks,

    pub fn bind(client: *client_api.Client, hooks: Hooks) !?Manager {
        const globals = if (client.globals.items.len == 0)
            try client.enumerateGlobals()
        else
            client.globals.items;
        for (globals) |global| {
            if (!std.mem.eql(u8, global.interface, "river_layer_shell_v1")) continue;
            const proxy = client.registry.bind(
                global.name,
                wayland.client.river.LayerShellV1,
                @min(global.version, 1),
            ) catch return error.BindFailed;
            return .{ .allocator = client.allocator, .proxy = proxy, .hooks = hooks };
        }
        return null;
    }

    pub fn deinit(self: *Manager) void {
        for (self.outputs.items) |output| output.destroy(true);
        for (self.seats.items) |seat| seat.destroy(true);
        self.outputs.deinit(self.allocator);
        self.seats.deinit(self.allocator);
        self.proxy.destroy();
        self.* = undefined;
    }

    pub fn abandon(self: *Manager) void {
        for (self.outputs.items) |output| output.destroy(false);
        for (self.seats.items) |seat| seat.destroy(false);
        self.outputs.deinit(self.allocator);
        self.seats.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addOutput(self: *Manager, river_output: *wayland.client.river.OutputV1) !void {
        const child = try self.allocator.create(Output);
        errdefer self.allocator.destroy(child);
        const proxy = try self.proxy.getOutput(river_output);
        errdefer proxy.destroy();
        child.* = .{ .owner = self, .river_output = river_output, .proxy = proxy };
        proxy.setListener(*Output, onOutputEvent, child);
        try self.outputs.append(self.allocator, child);
    }

    pub fn addSeat(self: *Manager, river_seat: *wayland.client.river.SeatV1) !void {
        const child = try self.allocator.create(Seat);
        errdefer self.allocator.destroy(child);
        const proxy = try self.proxy.getSeat(river_seat);
        errdefer proxy.destroy();
        child.* = .{ .owner = self, .river_seat = river_seat, .proxy = proxy };
        proxy.setListener(*Seat, onSeatEvent, child);
        try self.seats.append(self.allocator, child);
    }

    pub fn removeOutput(self: *Manager, river_output: *wayland.client.river.OutputV1) void {
        for (self.outputs.items, 0..) |child, index| {
            if (child.river_output != river_output) continue;
            _ = self.outputs.orderedRemove(index);
            child.destroy(true);
            return;
        }
    }

    pub fn removeSeat(self: *Manager, river_seat: *wayland.client.river.SeatV1) void {
        for (self.seats.items, 0..) |child, index| {
            if (child.river_seat != river_seat) continue;
            _ = self.seats.orderedRemove(index);
            child.destroy(true);
            return;
        }
    }

    pub fn noteWindowFocus(
        self: *Manager,
        river_seat: *wayland.client.river.SeatV1,
        window: ?*wayland.client.river.WindowV1,
    ) void {
        for (self.seats.items) |child| {
            if (child.river_seat == river_seat) {
                child.last_window = window;
                if (window == null) child.restore_pending = false;
                return;
            }
        }
    }

    pub fn removeWindow(self: *Manager, window: *wayland.client.river.WindowV1) void {
        for (self.seats.items) |child| {
            if (child.last_window == window) {
                child.last_window = null;
                child.restore_pending = false;
            }
        }
    }

    /// Restore the seat's last window after River reports focus_none. This
    /// must be called from the following manage sequence.
    pub fn restoreWindowFocus(self: *Manager) void {
        for (self.seats.items) |child| {
            if (!child.restore_pending) continue;
            child.restore_pending = false;
            if (child.last_window) |window| child.river_seat.focusWindow(window);
        }
    }

    /// Must be called only inside a River manage sequence.
    pub fn setDefaultOutput(self: *Manager, river_output: *wayland.client.river.OutputV1) void {
        for (self.outputs.items) |child| {
            if (child.river_output == river_output) {
                child.proxy.setDefault();
                return;
            }
        }
    }
};

const Output = struct {
    owner: *Manager,
    river_output: *wayland.client.river.OutputV1,
    proxy: *wayland.client.river.LayerShellOutputV1,
    area: ?Area = null,

    fn destroy(self: *Output, send_request: bool) void {
        const allocator = self.owner.allocator;
        if (send_request) self.proxy.destroy();
        self.* = undefined;
        allocator.destroy(self);
    }
};

const Seat = struct {
    owner: *Manager,
    river_seat: *wayland.client.river.SeatV1,
    proxy: *wayland.client.river.LayerShellSeatV1,
    focus: Focus = .none,
    last_window: ?*wayland.client.river.WindowV1 = null,
    restore_pending: bool = false,

    fn destroy(self: *Seat, send_request: bool) void {
        const allocator = self.owner.allocator;
        if (send_request) self.proxy.destroy();
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn onOutputEvent(
    _: *wayland.client.river.LayerShellOutputV1,
    event: wayland.client.river.LayerShellOutputV1.Event,
    output: *Output,
) void {
    switch (event) {
        .non_exclusive_area => |area| {
            output.area = .{ .x = area.x, .y = area.y, .width = area.width, .height = area.height };
            if (output.owner.hooks.on_area) |hook|
                hook(output.owner.hooks.context, output.river_output, output.area.?);
        },
    }
}

fn onSeatEvent(
    _: *wayland.client.river.LayerShellSeatV1,
    event: wayland.client.river.LayerShellSeatV1.Event,
    seat: *Seat,
) void {
    seat.focus = switch (event) {
        .focus_exclusive => .exclusive,
        .focus_non_exclusive => .non_exclusive,
        .focus_none => .none,
    };
    seat.restore_pending = seat.focus == .none and seat.last_window != null;
    if (seat.owner.hooks.on_focus) |hook|
        hook(seat.owner.hooks.context, seat.river_seat, seat.focus);
}

test "River layer shell focus is explicit state" {
    try std.testing.expect(Focus.exclusive != Focus.none);
}
