//! Standalone Whirlpool graphics host.
//!
//! Studio uses ordinary xdg-shell plus a Vulkan Wayland surface. It cannot
//! import or bind River protocols, so previewing graphics never competes for
//! River's window-manager role.

const std = @import("std");
const graphics = @import("whirlpool-graphics");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const vulkan = @import("vulkan_presenter.zig");

const log = std.log.scoped(.studio);

pub fn run() !void {
    const allocator = std.heap.page_allocator;
    const host = try allocator.create(Host);
    defer allocator.destroy(host);
    try host.init();
    defer host.deinit();
    try host.run();
}

const Host = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    wl_surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    toplevel: ?*xdg.Toplevel = null,
    width: u32 = 960,
    height: u32 = 600,
    configured: bool = false,
    running: bool = true,
    frame_ready: bool = true,
    frame_callback: ?*wl.Callback = null,
    scene: ?graphics.Scene = null,
    presenter: ?vulkan.Presenter = null,
    pixels: []u8 = &.{},

    fn init(self: *Host) !void {
        const display = try wl.Display.connect(null);
        const registry = display.getRegistry() catch |err| {
            display.disconnect();
            return err;
        };
        self.* = .{ .display = display, .registry = registry };
        errdefer self.deinit();

        registry.setListener(*Host, registryListener, self);
        if (display.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
        if (self.compositor == null) return error.CompositorUnavailable;
        if (self.wm_base == null) return error.XdgShellUnavailable;

        try self.createWindow();
        while (!self.configured and self.running) {
            if (display.dispatch() != .SUCCESS) return error.WaylandDispatchFailed;
        }
        if (!self.running) return error.WindowClosedBeforeConfigure;

        self.scene = try graphics.Scene.init(std.heap.page_allocator);
        self.presenter = try vulkan.Presenter.init(
            self.display,
            self.wl_surface.?,
            self.width,
            self.height,
        );
        const name = self.presenter.?.deviceName();
        log.info("ready: Vulkan {s}", .{name});
    }

    fn deinit(self: *Host) void {
        if (self.presenter) |*presenter| presenter.deinit();
        if (self.scene) |*scene| scene.deinit();
        if (self.pixels.len != 0) std.heap.page_allocator.free(self.pixels);
        if (self.frame_callback) |callback| callback.destroy();
        if (self.toplevel) |toplevel| toplevel.destroy();
        if (self.xdg_surface) |surface| surface.destroy();
        if (self.wl_surface) |surface| surface.destroy();
        if (self.wm_base) |wm_base| wm_base.destroy();
        if (self.compositor) |compositor| compositor.destroy();
        self.registry.destroy();
        self.display.disconnect();
    }

    fn createWindow(self: *Host) !void {
        self.wm_base.?.setListener(*Host, wmBaseListener, self);
        self.wl_surface = try self.compositor.?.createSurface();
        self.xdg_surface = try self.wm_base.?.getXdgSurface(self.wl_surface.?);
        self.xdg_surface.?.setListener(*Host, xdgSurfaceListener, self);
        self.toplevel = try self.xdg_surface.?.getToplevel();
        self.toplevel.?.setListener(*Host, toplevelListener, self);
        self.toplevel.?.setTitle("Whirlpool Studio — Vulkan");
        self.toplevel.?.setAppId("whirlpool-studio");
        self.wl_surface.?.commit();
    }

    fn run(self: *Host) !void {
        while (self.running) {
            if (self.frame_ready) {
                if (!(try self.render())) continue;
            }
            if (self.display.dispatch() != .SUCCESS) return error.WaylandDispatchFailed;
        }
    }

    /// Returns false when swapchain recreation consumed this iteration and no
    /// Wayland frame callback remains armed.
    fn render(self: *Host) !bool {
        const presenter = &self.presenter.?;
        try presenter.ensureSize(self.width, self.height);
        const extent = presenter.extent();
        try self.ensurePixelBuffer(extent[0], extent[1]);
        try self.scene.?.render(self.pixels, extent[0], extent[1]);

        // Vulkan's Wayland WSI commits the presented buffer. Queue the frame
        // request first so the compositor associates it with that commit.
        const callback = try self.wl_surface.?.frame();
        self.frame_callback = callback;
        errdefer {
            callback.destroy();
            self.frame_callback = null;
        }
        callback.setListener(*Host, frameListener, self);
        if (!(try presenter.present(self.pixels))) {
            callback.destroy();
            self.frame_callback = null;
            self.frame_ready = true;
            return false;
        }

        self.frame_ready = false;
        return true;
    }

    fn ensurePixelBuffer(self: *Host, width: u32, height: u32) !void {
        const pixel_count = try std.math.mul(usize, width, height);
        const required = try std.math.mul(usize, pixel_count, 4);
        if (self.pixels.len == required) return;
        if (self.pixels.len != 0) std.heap.page_allocator.free(self.pixels);
        self.pixels = try std.heap.page_allocator.alloc(u8, required);
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, host: *Host) void {
    switch (event) {
        .global => |global| {
            const interface = std.mem.span(global.interface);
            if (std.mem.eql(u8, interface, std.mem.span(wl.Compositor.interface.name))) {
                host.compositor = registry.bind(
                    global.name,
                    wl.Compositor,
                    @min(global.version, 6),
                ) catch null;
            } else if (std.mem.eql(u8, interface, std.mem.span(xdg.WmBase.interface.name))) {
                host.wm_base = registry.bind(
                    global.name,
                    xdg.WmBase,
                    @min(global.version, 6),
                ) catch null;
            }
        },
        .global_remove => {},
    }
}

fn wmBaseListener(_: *xdg.WmBase, event: xdg.WmBase.Event, host: *Host) void {
    switch (event) {
        .ping => |ping| host.wm_base.?.pong(ping.serial),
    }
}

fn xdgSurfaceListener(_: *xdg.Surface, event: xdg.Surface.Event, host: *Host) void {
    switch (event) {
        .configure => |configure| {
            host.xdg_surface.?.ackConfigure(configure.serial);
            host.configured = true;
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, host: *Host) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0 and configure.height > 0) {
                host.width = @intCast(configure.width);
                host.height = @intCast(configure.height);
                if (host.presenter) |*presenter| presenter.requestResize();
            }
        },
        .close => host.running = false,
        else => {},
    }
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, host: *Host) void {
    switch (event) {
        .done => {
            callback.destroy();
            host.frame_callback = null;
            host.frame_ready = true;
        },
    }
}
