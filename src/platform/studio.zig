//! Standalone Whirlpool graphics host.
//!
//! Studio uses the ordinary xdg-shell protocol. This file cannot import or
//! bind any River protocol, which makes the no-window-manager guarantee a
//! build-time property rather than a convention in shared startup code.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const c = @cImport({
    @cDefine("WL_EGL_PLATFORM", "1");
    @cInclude("EGL/egl.h");
    @cInclude("GLES3/gl3.h");
});

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
    egl_window: ?*wl.EglWindow = null,
    egl_display: c.EGLDisplay = c.EGL_NO_DISPLAY,
    egl_context: c.EGLContext = c.EGL_NO_CONTEXT,
    egl_surface: c.EGLSurface = c.EGL_NO_SURFACE,
    width: u32 = 960,
    height: u32 = 600,
    configured: bool = false,
    running: bool = true,
    frame_ready: bool = true,
    frame_number: u64 = 0,

    fn init(self: *Host) !void {
        const display = try wl.Display.connect(null);
        const registry = display.getRegistry() catch |err| {
            display.disconnect();
            return err;
        };

        self.* = .{
            .display = display,
            .registry = registry,
        };
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
        try self.initEgl();
    }

    fn deinit(self: *Host) void {
        if (self.egl_display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(
                self.egl_display,
                c.EGL_NO_SURFACE,
                c.EGL_NO_SURFACE,
                c.EGL_NO_CONTEXT,
            );
            if (self.egl_surface != c.EGL_NO_SURFACE) {
                _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
            }
            if (self.egl_context != c.EGL_NO_CONTEXT) {
                _ = c.eglDestroyContext(self.egl_display, self.egl_context);
            }
            _ = c.eglTerminate(self.egl_display);
        }
        if (self.egl_window) |window| window.destroy();
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
        self.toplevel.?.setTitle("Whirlpool Studio");
        self.toplevel.?.setAppId("whirlpool-studio");
        self.wl_surface.?.commit();
    }

    fn initEgl(self: *Host) !void {
        self.egl_display = c.eglGetDisplay(@ptrCast(self.display));
        if (self.egl_display == c.EGL_NO_DISPLAY) return error.EglDisplayUnavailable;

        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(self.egl_display, &major, &minor) == c.EGL_FALSE) {
            return error.EglInitializationFailed;
        }
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == c.EGL_FALSE) return error.EglBindFailed;

        const config_attributes = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_NONE,
        };
        var config: c.EGLConfig = null;
        var config_count: c.EGLint = 0;
        if (c.eglChooseConfig(
            self.egl_display,
            &config_attributes,
            &config,
            1,
            &config_count,
        ) == c.EGL_FALSE or config_count == 0) return error.EglConfigUnavailable;

        const context_attributes = [_]c.EGLint{
            c.EGL_CONTEXT_CLIENT_VERSION, 3,
            c.EGL_NONE,
        };
        self.egl_context = c.eglCreateContext(
            self.egl_display,
            config,
            c.EGL_NO_CONTEXT,
            &context_attributes,
        );
        if (self.egl_context == c.EGL_NO_CONTEXT) return error.EglContextCreationFailed;

        self.egl_window = try wl.EglWindow.create(
            self.wl_surface.?,
            @intCast(self.width),
            @intCast(self.height),
        );
        self.egl_surface = c.eglCreateWindowSurface(
            self.egl_display,
            config,
            @ptrCast(self.egl_window.?),
            null,
        );
        if (self.egl_surface == c.EGL_NO_SURFACE) return error.EglSurfaceCreationFailed;
        if (c.eglMakeCurrent(
            self.egl_display,
            self.egl_surface,
            self.egl_surface,
            self.egl_context,
        ) == c.EGL_FALSE) return error.EglMakeCurrentFailed;
        _ = c.eglSwapInterval(self.egl_display, 1);

        log.info("ready: EGL {d}.{d}, OpenGL ES {s}", .{
            major,
            minor,
            std.mem.span(c.glGetString(c.GL_VERSION)),
        });
    }

    fn run(self: *Host) !void {
        while (self.running) {
            if (self.frame_ready) try self.render();
            if (self.display.dispatch() != .SUCCESS) return error.WaylandDispatchFailed;
        }
    }

    fn render(self: *Host) !void {
        self.frame_ready = false;
        const callback = try self.wl_surface.?.frame();
        callback.setListener(*Host, frameListener, self);

        const phase = @as(f32, @floatFromInt(self.frame_number % 480)) / 480.0;
        const accent = 0.32 + 0.12 * @sin(phase * std.math.tau);
        c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glClearColor(0.035, 0.045, 0.065, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        // A deliberately tiny first scene: enough to exercise resize,
        // scissoring, color space, swaps, and frame callbacks before Snail is
        // connected to this caller-owned context.
        c.glEnable(c.GL_SCISSOR_TEST);
        clearRect(self, 48, 48, self.width -| 96, self.height -| 96, .{ 0.07, 0.09, 0.13, 1.0 });
        clearRect(self, 80, 88, self.width -| 160, 72, .{ 0.10, accent, 0.34, 1.0 });
        clearRect(self, 80, 184, (self.width -| 184) / 2, self.height -| 272, .{ 0.13, 0.16, 0.22, 1.0 });
        clearRect(self, self.width / 2 + 12, 184, self.width / 2 -| 92, self.height -| 272, .{ 0.09, 0.12, 0.18, 1.0 });
        c.glDisable(c.GL_SCISSOR_TEST);

        if (c.eglSwapBuffers(self.egl_display, self.egl_surface) == c.EGL_FALSE) {
            return error.EglSwapFailed;
        }
        self.frame_number +%= 1;
    }
};

fn clearRect(host: *const Host, x: u32, y_from_top: u32, width: u32, height: u32, color: [4]f32) void {
    if (width == 0 or height == 0 or y_from_top >= host.height) return;
    c.glScissor(
        @intCast(x),
        @intCast(host.height -| y_from_top -| height),
        @intCast(width),
        @intCast(height),
    );
    c.glClearColor(color[0], color[1], color[2], color[3]);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
}

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
                if (host.egl_window) |window| {
                    window.resize(configure.width, configure.height, 0, 0);
                }
            }
        },
        .close => host.running = false,
        else => {},
    }
}

fn frameListener(_: *wl.Callback, event: wl.Callback.Event, host: *Host) void {
    switch (event) {
        .done => host.frame_ready = true,
    }
}
