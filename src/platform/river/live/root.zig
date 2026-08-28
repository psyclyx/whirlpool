//! Live River v5 manager lifecycle over generated Wayland bindings.
//!
//! This module owns manager acquisition and sequence ordering.  Child object
//! listeners are layered separately so generated protocol details never leak
//! into the host facts or WM policy modules.

const std = @import("std");
const wayland = @import("wayland");
const wayland_client = @import("whirlpool-wayland-client");
pub const LayerShell = @import("whirlpool-river-layer-shell");
const river_layer_shell = LayerShell;
const ListenerCallbacks = @import("listeners.zig").Callbacks(Manager);

pub const ShellPosition = struct { x: i32, y: i32 };

pub const State = enum { claimed, managing, rendering, stopping, finished, unavailable, destroyed };
pub const Error = error{ MissingManagerGlobal, BindFailed, InvalidState, Disconnected, RolesStillLive };

pub const OutputShellRole = struct {
    output: *wayland.client.river.OutputV1,
    surface: *wayland.client.wl.Surface,
    shell_surface: *wayland.client.river.ShellSurfaceV1,
    node: *wayland.client.river.NodeV1,
    retirement_requested: bool = false,
};

/// A decoration role is one ownership unit.  The manager owns both the
/// compositor surface and the River role; callers never have to remember a
/// second teardown path or accidentally reuse a surface with a new role.
pub const DecorationRole = struct {
    window: *wayland.client.river.WindowV1,
    surface: *wayland.client.wl.Surface,
    decoration: *wayland.client.river.DecorationV1,
    retirement_requested: bool = false,
};

pub const Hooks = struct {
    context: ?*anyopaque = null,
    /// Deferred hooks only record transaction boundaries. Their owner must
    /// finish them from an after-dispatch safe point before another read.
    defer_transactions: bool = false,
    /// A non-deferred hook owns the sequence and must call finish before
    /// returning. Null means use the legal empty/native fallback.
    on_manage_start: ?*const fn (*Manager, ?*anyopaque) anyerror!void = null,
    on_render_start: ?*const fn (*Manager, ?*anyopaque) anyerror!void = null,
    on_session_locked: ?*const fn (*Manager, ?*anyopaque) anyerror!void = null,
    on_session_unlocked: ?*const fn (*Manager, ?*anyopaque) anyerror!void = null,
    on_window_created: ?*const fn (*Manager, *wayland.client.river.WindowV1, *wayland.client.river.NodeV1, ?*anyopaque) anyerror!void = null,
    on_output_created: ?*const fn (*Manager, *wayland.client.river.OutputV1, ?*anyopaque) anyerror!void = null,
    on_seat_created: ?*const fn (*Manager, *wayland.client.river.SeatV1, ?*anyopaque) anyerror!void = null,
    on_shell_surface_created: ?*const fn (*Manager, *wayland.client.river.ShellSurfaceV1, ?*anyopaque) anyerror!void = null,
    on_decoration_created: ?*const fn (*Manager, *wayland.client.river.DecorationV1, ?*anyopaque) anyerror!void = null,
    on_pointer_binding_created: ?*const fn (*Manager, *wayland.client.river.PointerBindingV1, ?*anyopaque) anyerror!void = null,
    on_window_event: ?*const fn (*Manager, *wayland.client.river.WindowV1, wayland.client.river.WindowV1.Event, ?*anyopaque) anyerror!void = null,
    on_output_event: ?*const fn (*Manager, *wayland.client.river.OutputV1, wayland.client.river.OutputV1.Event, ?*anyopaque) anyerror!void = null,
    on_seat_event: ?*const fn (*Manager, *wayland.client.river.SeatV1, wayland.client.river.SeatV1.Event, ?*anyopaque) anyerror!void = null,
    on_layer_output_area: ?*const fn (*Manager, *wayland.client.river.OutputV1, river_layer_shell.Area, ?*anyopaque) anyerror!void = null,
    on_layer_seat_focus: ?*const fn (*Manager, *wayland.client.river.SeatV1, river_layer_shell.Focus, ?*anyopaque) anyerror!void = null,
    on_pointer_binding_event: ?*const fn (*Manager, *wayland.client.river.PointerBindingV1, wayland.client.river.PointerBindingV1.Event, ?*anyopaque) anyerror!void = null,
    on_shell_surface_destroyed: ?*const fn (*Manager, *wayland.client.river.ShellSurfaceV1, ?*anyopaque) anyerror!void = null,
    on_decoration_destroyed: ?*const fn (*Manager, *wayland.client.river.DecorationV1, ?*anyopaque) anyerror!void = null,
    on_pointer_binding_destroyed: ?*const fn (*Manager, *wayland.client.river.PointerBindingV1, ?*anyopaque) anyerror!void = null,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    client: *wayland_client.Client,
    proxy: *wayland.client.river.WindowManagerV1,
    layer_shell: ?river_layer_shell.Manager = null,
    state: State = .claimed,
    manage_starts: u64 = 0,
    render_starts: u64 = 0,
    windows: std.ArrayList(*wayland.client.river.WindowV1) = .empty,
    outputs: std.ArrayList(*wayland.client.river.OutputV1) = .empty,
    seats: std.ArrayList(*wayland.client.river.SeatV1) = .empty,
    nodes: std.ArrayList(*wayland.client.river.NodeV1) = .empty,
    shell_surfaces: std.ArrayList(*wayland.client.river.ShellSurfaceV1) = .empty,
    decorations: std.ArrayList(*wayland.client.river.DecorationV1) = .empty,
    pointer_bindings: std.ArrayList(*wayland.client.river.PointerBindingV1) = .empty,
    output_shell_roles: std.ArrayList(OutputShellRole) = .empty,
    decoration_roles: std.ArrayList(DecorationRole) = .empty,
    listener_error: ?anyerror = null,
    hooks: Hooks = .{},

    pub fn claim(client: *wayland_client.Client) !*Manager {
        // `bindCompositor` has already completed the initial registry
        // roundtrip in the production startup path. Repeating it after
        // installing this manager listener can dispatch the compositor's
        // initial output/seat events before the caller has installed its
        // hooks, silently losing the first lifecycle epoch.
        const globals = if (client.globals.items.len != 0)
            client.globals.items
        else
            try client.enumerateGlobals();
        var global_name: ?u32 = null;
        var global_version: u32 = 0;
        for (globals) |global| {
            if (std.mem.eql(u8, global.interface, "river_window_manager_v1")) {
                global_name = global.name;
                global_version = global.version;
                break;
            }
        }
        const name = global_name orelse return error.MissingManagerGlobal;
        const proxy = client.registry.bind(name, wayland.client.river.WindowManagerV1, @min(global_version, 5)) catch return error.BindFailed;
        const allocator = client.allocator;
        const manager = allocator.create(Manager) catch return error.OutOfMemory;
        errdefer allocator.destroy(manager);
        errdefer proxy.destroy();
        manager.* = .{ .allocator = allocator, .client = client, .proxy = proxy };
        manager.layer_shell = try river_layer_shell.Manager.bind(client, .{
            .context = manager,
            .on_area = ListenerCallbacks.onLayerOutputArea,
            .on_focus = ListenerCallbacks.onLayerSeatFocus,
        });
        proxy.setListener(*Manager, ListenerCallbacks.onManagerEvent, manager);
        return manager;
    }

    /// Create one compositor-owned wl_surface and River shell role for an
    /// output. The role is retained as one unit, so a failed append or hook
    /// cannot leave either half observable. The caller must invoke this only
    /// from the deferred post-dispatch safe point.
    pub fn createOutputShellRole(
        self: *Manager,
        compositor: *wayland.client.wl.Compositor,
        output: *wayland.client.river.OutputV1,
    ) !usize {
        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const shell = self.proxy.getShellSurface(surface) catch return error.BindFailed;
        errdefer shell.destroy();
        const node = shell.getNode() catch return error.BindFailed;
        errdefer node.destroy();
        try self.output_shell_roles.append(self.allocator, .{
            .output = output,
            .surface = surface,
            .shell_surface = shell,
            .node = node,
        });
        self.shell_surfaces.append(self.allocator, shell) catch {
            _ = self.output_shell_roles.pop();
            shell.destroy();
            surface.destroy();
            return error.OutOfMemory;
        };
        self.nodes.append(self.allocator, node) catch {
            _ = self.shell_surfaces.pop();
            _ = self.output_shell_roles.pop();
            shell.destroy();
            surface.destroy();
            return error.OutOfMemory;
        };
        if (self.hooks.on_shell_surface_created) |hook| hook(self, shell, self.hooks.context) catch |err| {
            if (self.hooks.on_shell_surface_destroyed) |rollback| rollback(self, shell, self.hooks.context) catch |rollback_err| {
                self.listener_error = rollback_err;
            };
            _ = self.shell_surfaces.pop();
            _ = self.nodes.pop();
            _ = self.output_shell_roles.pop();
            shell.destroy();
            surface.destroy();
            return err;
        };
        return self.output_shell_roles.items.len - 1;
    }

    /// Mark a role for deferred teardown. The role proxy and wl_surface remain
    /// live until the presentation owner explicitly proves release safety and
    /// calls finishOutputShellRoleRetirement.
    pub fn requestOutputShellRoleRetirement(self: *Manager, index: usize) Error!void {
        if (index >= self.output_shell_roles.items.len) return error.InvalidState;
        self.output_shell_roles.items[index].retirement_requested = true;
    }

    pub fn finishOutputShellRoleRetirement(self: *Manager, index: usize) Error!void {
        if (index >= self.output_shell_roles.items.len or
            !self.output_shell_roles.items[index].retirement_requested)
            return error.InvalidState;
        const role = self.output_shell_roles.orderedRemove(index);
        for (self.shell_surfaces.items, 0..) |surface, shell_index| {
            if (surface == role.shell_surface) {
                _ = self.shell_surfaces.orderedRemove(shell_index);
                break;
            }
        }
        if (self.hooks.on_shell_surface_destroyed) |hook| hook(self, role.shell_surface, self.hooks.context) catch |err| {
            self.listener_error = err;
        };
        removeNode(self, role.node);
        role.node.destroy();
        role.shell_surface.destroy();
        role.surface.destroy();
    }

    /// Shell nodes have no meaningful default render-list position. Place
    /// them during the render transaction that applies their surface commit.
    pub fn placeOutputShellRoles(
        self: *Manager,
        context: ?*anyopaque,
        resolve: *const fn (?*anyopaque, *wayland.client.river.OutputV1) ?ShellPosition,
    ) void {
        for (self.output_shell_roles.items) |role| {
            if (resolve(context, role.output)) |position| role.node.setPosition(position.x, position.y);
            role.node.placeTop();
        }
    }

    pub fn placeDecorationRoles(self: *Manager, height: i32) void {
        for (self.decoration_roles.items) |role| role.decoration.setOffset(0, -height);
    }

    /// Create a compositor-owned surface and assign it a River decoration
    /// role.  This is intentionally one operation so an allocation or hook
    /// failure cannot leave an untracked surface or role behind.
    pub fn createDecorationRole(
        self: *Manager,
        compositor: *wayland.client.wl.Compositor,
        window: *wayland.client.river.WindowV1,
        above: bool,
    ) !usize {
        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const decoration = if (above)
            (try window.getDecorationAbove(surface))
        else
            (try window.getDecorationBelow(surface));
        errdefer decoration.destroy();

        try self.decorations.append(self.allocator, decoration);
        errdefer _ = self.decorations.pop();
        try self.decoration_roles.append(self.allocator, .{
            .window = window,
            .surface = surface,
            .decoration = decoration,
        });
        errdefer _ = self.decoration_roles.pop();
        if (self.hooks.on_decoration_created) |hook| hook(self, decoration, self.hooks.context) catch |err| {
            if (self.hooks.on_decoration_destroyed) |rollback| rollback(self, decoration, self.hooks.context) catch |rollback_err| {
                self.listener_error = rollback_err;
            };
            return err;
        };
        return self.decoration_roles.items.len - 1;
    }

    /// The matching finish call is the sole path which destroys the borrowed
    /// wl_surface. Callers keep retrying their release-safe protocol while this
    /// record remains marked and owned by the manager.
    pub fn requestDecorationRoleRetirement(self: *Manager, index: usize) Error!void {
        if (index >= self.decoration_roles.items.len) return error.InvalidState;
        self.decoration_roles.items[index].retirement_requested = true;
    }

    pub fn finishDecorationRoleRetirement(self: *Manager, index: usize) Error!void {
        if (index >= self.decoration_roles.items.len or
            !self.decoration_roles.items[index].retirement_requested)
            return error.InvalidState;
        const role = self.decoration_roles.orderedRemove(index);
        for (self.decorations.items, 0..) |decoration, decoration_index| {
            if (decoration == role.decoration) {
                _ = self.decorations.orderedRemove(decoration_index);
                break;
            }
        }
        if (self.hooks.on_decoration_destroyed) |hook| hook(self, role.decoration, self.hooks.context) catch |err| {
            self.listener_error = err;
        };
        role.decoration.destroy();
        role.surface.destroy();
    }

    pub fn requestDecorationsForWindowRetirement(self: *Manager, window: *wayland.client.river.WindowV1) void {
        for (self.decoration_roles.items) |*role| {
            if (role.window == window) role.retirement_requested = true;
        }
    }

    pub fn setHooks(self: *Manager, hooks: Hooks) Error!void {
        if (self.state != .claimed) return error.InvalidState;
        self.hooks = hooks;
    }

    pub fn takeListenerError(self: *Manager) ?anyerror {
        const failure = self.listener_error;
        self.listener_error = null;
        return failure;
    }

    pub fn manageFinish(self: *Manager) Error!void {
        if (self.state != .managing) return error.InvalidState;
        self.proxy.manageFinish();
        self.state = .claimed;
    }

    pub fn renderFinish(self: *Manager) Error!void {
        if (self.state != .rendering) return error.InvalidState;
        self.proxy.renderFinish();
        self.state = .claimed;
    }

    pub fn requestStop(self: *Manager) Error!void {
        if (self.state != .claimed) return error.InvalidState;
        self.proxy.stop();
        self.state = .stopping;
    }

    /// Create and retain a shell-surface proxy. The caller owns the wl_surface
    /// passed to River; this manager owns the returned River role proxy.
    pub fn createShellSurface(
        self: *Manager,
        surface: *wayland.client.wl.Surface,
    ) !*wayland.client.river.ShellSurfaceV1 {
        const created = try self.proxy.getShellSurface(surface);
        self.shell_surfaces.append(self.allocator, created) catch {
            created.destroy();
            return error.OutOfMemory;
        };
        if (self.hooks.on_shell_surface_created) |hook| hook(self, created, self.hooks.context) catch |err| {
            if (self.hooks.on_shell_surface_destroyed) |rollback| rollback(self, created, self.hooks.context) catch |rollback_err| {
                self.listener_error = rollback_err;
            };
            _ = self.shell_surfaces.pop();
            created.destroy();
            return err;
        };
        return created;
    }

    /// Create and retain a decoration proxy for a window-manager surface.
    pub fn createDecorationAbove(
        self: *Manager,
        window: *wayland.client.river.WindowV1,
        surface: *wayland.client.wl.Surface,
    ) !*wayland.client.river.DecorationV1 {
        return self.createDecoration(window.getDecorationAbove(surface));
    }

    /// Create and retain a decoration proxy for a window-manager surface.
    pub fn createDecorationBelow(
        self: *Manager,
        window: *wayland.client.river.WindowV1,
        surface: *wayland.client.wl.Surface,
    ) !*wayland.client.river.DecorationV1 {
        return self.createDecoration(window.getDecorationBelow(surface));
    }

    fn createDecoration(
        self: *Manager,
        result: anytype,
    ) !*wayland.client.river.DecorationV1 {
        const created = try result;
        self.decorations.append(self.allocator, created) catch {
            created.destroy();
            return error.OutOfMemory;
        };
        if (self.hooks.on_decoration_created) |hook| hook(self, created, self.hooks.context) catch |err| {
            _ = self.decorations.pop();
            created.destroy();
            return err;
        };
        return created;
    }

    /// Create and retain a pointer binding. Its events are dispatched through
    /// the manager so the binding remains owned for the whole manager lifetime.
    pub fn createPointerBinding(
        self: *Manager,
        seat: *wayland.client.river.SeatV1,
        button: u32,
        modifiers: wayland.client.river.SeatV1.Modifiers,
    ) !*wayland.client.river.PointerBindingV1 {
        const created = try seat.getPointerBinding(button, modifiers);
        self.pointer_bindings.append(self.allocator, created) catch {
            created.destroy();
            return error.OutOfMemory;
        };
        created.setListener(*Manager, ListenerCallbacks.onPointerBindingEvent, self);
        if (self.hooks.on_pointer_binding_created) |hook| hook(self, created, self.hooks.context) catch |err| {
            _ = self.pointer_bindings.pop();
            created.destroy();
            return err;
        };
        return created;
    }

    /// Used only after River's finished/unavailable event.  A disconnected
    /// display owns the proxy teardown and must not call this method.
    pub fn deinit(self: *Manager) Error!void {
        if (self.state != .finished and self.state != .unavailable) return error.InvalidState;
        if (self.output_shell_roles.items.len != 0 or self.decoration_roles.items.len != 0)
            return error.RolesStillLive;
        self.releaseCreatedObjects(true);
        if (self.layer_shell) |*layer_manager| layer_manager.deinit();
        for (self.windows.items) |window| window.destroy();
        for (self.outputs.items) |output| output.destroy();
        for (self.seats.items) |seat| seat.destroy();
        for (self.nodes.items) |node| node.destroy();
        self.windows.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        self.seats.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.shell_surfaces.deinit(self.allocator);
        self.decorations.deinit(self.allocator);
        self.pointer_bindings.deinit(self.allocator);
        self.output_shell_roles.deinit(self.allocator);
        self.decoration_roles.deinit(self.allocator);
        self.proxy.destroy();
        self.state = .destroyed;
        self.allocator.destroy(self);
    }

    /// Drop manager storage after the display has disconnected. The display
    /// teardown owns proxy destruction in that case, so this path must not
    /// send another Wayland request.
    pub fn abandon(self: *Manager) void {
        self.releaseCreatedObjects(false);
        if (self.layer_shell) |*layer_manager| layer_manager.abandon();
        self.windows.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        self.seats.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.shell_surfaces.deinit(self.allocator);
        self.decorations.deinit(self.allocator);
        self.pointer_bindings.deinit(self.allocator);
        self.output_shell_roles.deinit(self.allocator);
        self.decoration_roles.deinit(self.allocator);
        self.state = .destroyed;
        self.allocator.destroy(self);
    }

    fn releaseCreatedObjects(self: *Manager, destroy: bool) void {
        for (self.pointer_bindings.items) |binding| {
            if (self.hooks.on_pointer_binding_destroyed) |hook| hook(self, binding, self.hooks.context) catch |err| {
                self.listener_error = err;
            };
            if (destroy) binding.destroy();
        }
        for (self.decorations.items) |decoration| {
            if (self.hooks.on_decoration_destroyed) |hook| hook(self, decoration, self.hooks.context) catch |err| {
                self.listener_error = err;
            };
            if (destroy) decoration.destroy();
        }
        for (self.shell_surfaces.items) |surface| {
            if (self.hooks.on_shell_surface_destroyed) |hook| hook(self, surface, self.hooks.context) catch |err| {
                self.listener_error = err;
            };
            if (destroy) surface.destroy();
        }
        for (self.nodes.items) |node| {
            if (destroy) node.destroy();
        }
        for (self.output_shell_roles.items) |role| {
            if (destroy) role.surface.destroy();
        }
        self.decoration_roles.clearRetainingCapacity();
        self.output_shell_roles.clearRetainingCapacity();
    }

    fn removeNode(self: *Manager, target: *wayland.client.river.NodeV1) void {
        for (self.nodes.items, 0..) |node, index| {
            if (node == target) {
                _ = self.nodes.orderedRemove(index);
                return;
            }
        }
    }
};

test "live manager type-checks generated River v5 lifecycle without a socket" {
    try std.testing.expect(@sizeOf(Manager) > 0);
    _ = Manager.createShellSurface;
    _ = Manager.createDecorationAbove;
    _ = Manager.createDecorationBelow;
    _ = Manager.createPointerBinding;
    _ = Manager.createOutputShellRole;
    _ = Manager.createDecorationRole;
    _ = Manager.requestOutputShellRoleRetirement;
    _ = Manager.finishOutputShellRoleRetirement;
    _ = Manager.placeOutputShellRoles;
    _ = Manager.requestDecorationRoleRetirement;
    _ = Manager.finishDecorationRoleRetirement;
}

test "role retirement requests retain protocol ownership until explicit finish" {
    var manager: Manager = .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .proxy = undefined,
    };
    defer manager.output_shell_roles.deinit(manager.allocator);
    defer manager.decoration_roles.deinit(manager.allocator);

    try manager.output_shell_roles.append(manager.allocator, .{
        .output = @ptrFromInt(0x1000),
        .surface = @ptrFromInt(0x1010),
        .shell_surface = @ptrFromInt(0x1020),
        .node = @ptrFromInt(0x1030),
    });
    try manager.decoration_roles.append(manager.allocator, .{
        .window = @ptrFromInt(0x2000),
        .surface = @ptrFromInt(0x2010),
        .decoration = @ptrFromInt(0x2020),
    });

    try manager.requestOutputShellRoleRetirement(0);
    try manager.requestDecorationRoleRetirement(0);
    try std.testing.expect(manager.output_shell_roles.items[0].retirement_requested);
    try std.testing.expect(manager.decoration_roles.items[0].retirement_requested);
    try std.testing.expectEqual(@as(usize, 1), manager.output_shell_roles.items.len);
    try std.testing.expectEqual(@as(usize, 1), manager.decoration_roles.items.len);
}

const SessionHookTrace = struct {
    locked: usize = 0,
    unlocked: usize = 0,

    fn lockedHook(_: *Manager, raw: ?*anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.locked += 1;
    }

    fn unlockedHook(_: *Manager, raw: ?*anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.unlocked += 1;
    }
};

test "manager forwards session lock changes through hooks" {
    var trace = SessionHookTrace{};
    var manager: Manager = .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .proxy = undefined,
        .hooks = .{
            .context = @ptrCast(&trace),
            .on_session_locked = SessionHookTrace.lockedHook,
            .on_session_unlocked = SessionHookTrace.unlockedHook,
        },
    };

    ListenerCallbacks.onManagerEvent(undefined, .session_locked, &manager);
    ListenerCallbacks.onManagerEvent(undefined, .session_unlocked, &manager);

    try std.testing.expectEqual(@as(usize, 1), trace.locked);
    try std.testing.expectEqual(@as(usize, 1), trace.unlocked);
    try std.testing.expect(manager.takeListenerError() == null);
}

fn completedWithError(_: *Manager, _: ?*anyopaque) !void {
    return error.HookFailed;
}

test "manager does not retry finish after a hook has completed the phase" {
    var manager: Manager = .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .proxy = undefined,
        .hooks = .{
            .on_manage_start = struct {
                fn call(manager_ptr: *Manager, context: ?*anyopaque) !void {
                    manager_ptr.state = .claimed;
                    return completedWithError(manager_ptr, context);
                }
            }.call,
            .on_render_start = struct {
                fn call(manager_ptr: *Manager, context: ?*anyopaque) !void {
                    manager_ptr.state = .claimed;
                    return completedWithError(manager_ptr, context);
                }
            }.call,
        },
    };

    ListenerCallbacks.onManagerEvent(undefined, .manage_start, &manager);
    try std.testing.expectEqual(error.HookFailed, manager.takeListenerError().?);
    ListenerCallbacks.onManagerEvent(undefined, .render_start, &manager);
    try std.testing.expectEqual(error.HookFailed, manager.takeListenerError().?);
}
