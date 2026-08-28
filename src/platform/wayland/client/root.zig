//! Concrete client-side Wayland registry and display transport.
//!
//! This is deliberately below the River adapter: it knows generated Wayland
//! proxy types and wire sequencing, but it does not know WM policy, UI, or
//! graphics. River owns the protocol-specific listeners layered on this
//! client.

const std = @import("std");
const wayland = @import("wayland");

pub const Global = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    display: *wayland.client.wl.Display,
    registry: *wayland.client.wl.Registry,
    globals: std.ArrayList(Global) = .empty,
    listener_error: ?anyerror = null,

    /// The client is heap-owned because Wayland retains the listener context
    /// pointer until the registry is destroyed. Returning a value here would
    /// let that pointer dangle when the value moved out of this function.
    pub fn connect(allocator: std.mem.Allocator) !*Client {
        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);
        const display = wayland.client.wl.Display.connect(null) catch return error.ConnectFailed;
        errdefer wayland.client.wl.Display.disconnect(display);
        const registry = display.getRegistry() catch return error.OutOfMemory;
        client.* = .{ .allocator = allocator, .display = display, .registry = registry };
        registry.setListener(*Client, onRegistryEvent, client);
        return client;
    }

    pub fn deinit(self: *Client) void {
        const allocator = self.allocator;
        self.registry.destroy();
        self.display.disconnect();
        for (self.globals.items) |global| allocator.free(global.interface);
        self.globals.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Complete initial global enumeration. A roundtrip is the explicit
    /// boundary after which `globals` is a stable snapshot for the caller.
    pub fn enumerateGlobals(self: *Client) ![]const Global {
        try self.requireListenerHealthy();
        try self.roundtrip();
        try self.requireListenerHealthy();
        return self.globals.items;
    }

    /// Complete one explicit request/event roundtrip. Protocol adapters use
    /// this after installing listeners or binding a child object; callers do
    /// not need to reach through the client boundary to the generated display.
    pub fn roundtrip(self: *Client) !void {
        if (self.display.roundtrip() != .SUCCESS) return error.Disconnected;
    }

    pub fn fd(self: *const Client) i32 {
        return self.display.getFd();
    }

    /// Attempt one non-blocking Wayland read preparation. A false result means
    /// pending callbacks must be dispatched before the caller retries. Keep
    /// that dispatch visible to the event loop so host safe-point work runs
    /// while the display is not in the prepared-read state.
    pub fn prepareRead(self: *Client) !bool {
        try self.requireListenerHealthy();
        return self.display.prepareRead();
    }

    pub fn cancelRead(self: *Client) void {
        self.display.cancelRead();
    }

    pub fn readEvents(self: *Client) !void {
        if (self.display.readEvents() != .SUCCESS) return error.Disconnected;
    }

    pub fn dispatchPending(self: *Client) !void {
        if (self.display.dispatchPending() != .SUCCESS) return error.Disconnected;
        try self.requireListenerHealthy();
    }

    pub fn flush(self: *Client) !void {
        switch (self.display.flush()) {
            .SUCCESS => {},
            .AGAIN => return error.WouldBlock,
            else => return error.Disconnected,
        }
    }

    fn requireListenerHealthy(self: *const Client) !void {
        if (self.listener_error) |err| return err;
    }

    fn onRegistryEvent(
        _: *wayland.client.wl.Registry,
        event: wayland.client.wl.Registry.Event,
        client: *Client,
    ) void {
        switch (event) {
            .global => |global| {
                const interface = client.allocator.dupe(u8, std.mem.span(global.interface)) catch {
                    client.listener_error = error.OutOfMemory;
                    return;
                };
                client.globals.append(client.allocator, .{
                    .name = global.name,
                    .interface = interface,
                    .version = global.version,
                }) catch {
                    client.allocator.free(interface);
                    client.listener_error = error.OutOfMemory;
                };
            },
            .global_remove => |removed| {
                for (client.globals.items, 0..) |global, index| {
                    if (global.name == removed.name) {
                        client.allocator.free(global.interface);
                        _ = client.globals.orderedRemove(index);
                        break;
                    }
                }
            },
        }
    }
};

test "client transport type-checks the generated display lifecycle" {
    // No compositor is required for this test; the concrete connect path is
    // intentionally exercised only by nested-session integration tests.
    try std.testing.expect(@sizeOf(Client) > 0);
}
