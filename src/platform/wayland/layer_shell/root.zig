//! Portable `zwlr_layer_shell_v1` surface ownership.
//!
//! This is a client-side surface role. It is intentionally separate from
//! River's `river_layer_shell_v1`, which is the window-manager-side contract
//! for arranging and focusing other clients' layer surfaces.

const std = @import("std");
const wayland = @import("wayland");
const client_api = @import("whirlpool-wayland-client");

pub const Layer = wayland.client.zwlr.LayerShellV1.Layer;
pub const Anchor = wayland.client.zwlr.LayerSurfaceV1.Anchor;
pub const KeyboardInteractivity = wayland.client.zwlr.LayerSurfaceV1.KeyboardInteractivity;

pub const Config = struct {
    output: ?*wayland.client.wl.Output = null,
    layer: Layer = .top,
    namespace: [:0]const u8 = "whirlpool",
    width: u32 = 0,
    height: u32 = 0,
    anchor: Anchor = .{},
    exclusive_zone: i32 = 0,
    margin_top: i32 = 0,
    margin_right: i32 = 0,
    margin_bottom: i32 = 0,
    margin_left: i32 = 0,
    keyboard_interactivity: KeyboardInteractivity = .none,
};

pub const Manager = struct {
    proxy: *wayland.client.zwlr.LayerShellV1,

    pub fn bind(client: *client_api.Client) !?Manager {
        const globals = if (client.globals.items.len == 0)
            try client.enumerateGlobals()
        else
            client.globals.items;
        for (globals) |global| {
            if (!std.mem.eql(u8, global.interface, "zwlr_layer_shell_v1")) continue;
            const proxy = client.registry.bind(
                global.name,
                wayland.client.zwlr.LayerShellV1,
                @min(global.version, 4),
            ) catch return error.BindFailed;
            return .{ .proxy = proxy };
        }
        return null;
    }

    pub fn deinit(self: *Manager) void {
        if (self.proxy.getVersion() >= wayland.client.zwlr.LayerShellV1.destroy_since_version)
            self.proxy.destroy()
        else
            @as(*wayland.client.wl.Proxy, @ptrCast(self.proxy)).destroy();
        self.* = undefined;
    }

    pub fn abandon(self: *Manager) void {
        @as(*wayland.client.wl.Proxy, @ptrCast(self.proxy)).destroy();
        self.* = undefined;
    }

    /// The returned owner is heap-stable because Wayland retains it as the
    /// configure listener context until the role is destroyed.
    pub fn createSurface(
        self: *Manager,
        allocator: std.mem.Allocator,
        compositor: *wayland.client.wl.Compositor,
        config: Config,
    ) !*Surface {
        const owner = try allocator.create(Surface);
        errdefer allocator.destroy(owner);
        const wl_surface = try compositor.createSurface();
        errdefer wl_surface.destroy();
        const role = try self.proxy.getLayerSurface(
            wl_surface,
            config.output,
            config.layer,
            config.namespace,
        );
        errdefer role.destroy();
        owner.* = .{
            .allocator = allocator,
            .wl_surface = wl_surface,
            .role = role,
            .width = config.width,
            .height = config.height,
        };
        role.setListener(*Surface, Surface.onEvent, owner);
        role.setSize(config.width, config.height);
        role.setAnchor(config.anchor);
        role.setExclusiveZone(config.exclusive_zone);
        role.setMargin(
            config.margin_top,
            config.margin_right,
            config.margin_bottom,
            config.margin_left,
        );
        role.setKeyboardInteractivity(config.keyboard_interactivity);
        wl_surface.commit();
        return owner;
    }
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    wl_surface: *wayland.client.wl.Surface,
    role: *wayland.client.zwlr.LayerSurfaceV1,
    width: u32,
    height: u32,
    configure_serial: ?u32 = null,
    generation: u64 = 0,
    closed: bool = false,

    pub fn deinit(self: *Surface) void {
        const allocator = self.allocator;
        self.role.destroy();
        self.wl_surface.destroy();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn abandon(self: *Surface) void {
        const allocator = self.allocator;
        @as(*wayland.client.wl.Proxy, @ptrCast(self.role)).destroy();
        @as(*wayland.client.wl.Proxy, @ptrCast(self.wl_surface)).destroy();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn takeConfigure(self: *Surface) ?struct { serial: u32, width: u32, height: u32 } {
        const serial = self.configure_serial orelse return null;
        self.configure_serial = null;
        return .{ .serial = serial, .width = self.width, .height = self.height };
    }

    fn onEvent(
        role: *wayland.client.zwlr.LayerSurfaceV1,
        event: wayland.client.zwlr.LayerSurfaceV1.Event,
        self: *Surface,
    ) void {
        switch (event) {
            .configure => |configure| {
                role.ackConfigure(configure.serial);
                if (configure.width != 0) self.width = configure.width;
                if (configure.height != 0) self.height = configure.height;
                self.configure_serial = configure.serial;
                self.generation +%= 1;
            },
            .closed => self.closed = true,
        }
    }
};

test "portable layer shell config keeps role policy outside transport" {
    const config: Config = .{
        .height = 32,
        .anchor = .{ .top = true, .left = true, .right = true },
        .exclusive_zone = 32,
    };
    try std.testing.expectEqual(@as(u32, 32), config.height);
    try std.testing.expect(config.anchor.top and config.anchor.left and config.anchor.right);
}
