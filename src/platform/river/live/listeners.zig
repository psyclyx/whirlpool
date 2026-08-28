//! Generated River and layer-shell event dispatch for the live manager.
//!
//! The manager owns protocol objects and transaction state. This adapter only
//! translates generated callbacks into those operations and the host hooks.

const wayland = @import("wayland");
const LayerShell = @import("whirlpool-river-layer-shell");

pub fn Callbacks(comptime Manager: type) type {
    return struct {
        pub fn onManagerEvent(
            _: *wayland.client.river.WindowManagerV1,
            event: wayland.client.river.WindowManagerV1.Event,
            self: *Manager,
        ) void {
            switch (event) {
                .manage_start => beginManage(self),
                .render_start => beginRender(self),
                .finished => if (self.state == .stopping) {
                    self.state = .finished;
                },
                .unavailable => self.state = .unavailable,
                .session_locked => runSessionHook(self, self.hooks.on_session_locked),
                .session_unlocked => runSessionHook(self, self.hooks.on_session_unlocked),
                .window => |created| addWindow(self, created.id),
                .output => |created| addOutput(self, created.id),
                .seat => |created| addSeat(self, created.id),
            }
        }

        pub fn onWindowEvent(
            window: *wayland.client.river.WindowV1,
            event: wayland.client.river.WindowV1.Event,
            self: *Manager,
        ) void {
            if (self.hooks.on_window_event) |hook|
                hook(self, window, event, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
            switch (event) {
                .closed => {
                    self.requestDecorationsForWindowRetirement(window);
                    if (self.layer_shell) |*layer_manager| layer_manager.removeWindow(window);
                    window.destroy();
                    removeProxy(wayland.client.river.WindowV1, &self.windows, window);
                },
                else => {},
            }
        }

        pub fn onOutputEvent(
            output: *wayland.client.river.OutputV1,
            event: wayland.client.river.OutputV1.Event,
            self: *Manager,
        ) void {
            if (self.hooks.on_output_event) |hook|
                hook(self, output, event, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
            switch (event) {
                .removed => {
                    for (self.output_shell_roles.items) |*role| {
                        if (role.output == output) role.retirement_requested = true;
                    }
                    if (self.layer_shell) |*layer_manager| layer_manager.removeOutput(output);
                    output.destroy();
                    removeProxy(wayland.client.river.OutputV1, &self.outputs, output);
                },
                else => {},
            }
        }

        pub fn onSeatEvent(
            seat: *wayland.client.river.SeatV1,
            event: wayland.client.river.SeatV1.Event,
            self: *Manager,
        ) void {
            switch (event) {
                .window_interaction => |interaction| if (self.layer_shell) |*layer_manager|
                    layer_manager.noteWindowFocus(seat, interaction.window),
                else => {},
            }
            if (self.hooks.on_seat_event) |hook|
                hook(self, seat, event, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
            switch (event) {
                .removed => {
                    if (self.layer_shell) |*layer_manager| layer_manager.removeSeat(seat);
                    seat.destroy();
                    removeProxy(wayland.client.river.SeatV1, &self.seats, seat);
                },
                else => {},
            }
        }

        pub fn onPointerBindingEvent(
            binding: *wayland.client.river.PointerBindingV1,
            event: wayland.client.river.PointerBindingV1.Event,
            self: *Manager,
        ) void {
            if (self.hooks.on_pointer_binding_event) |hook|
                hook(self, binding, event, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
        }

        pub fn onLayerOutputArea(
            context: ?*anyopaque,
            output: *wayland.client.river.OutputV1,
            area: LayerShell.Area,
        ) void {
            const self: *Manager = @ptrCast(@alignCast(context orelse return));
            if (self.hooks.on_layer_output_area) |hook|
                hook(self, output, area, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
        }

        pub fn onLayerSeatFocus(
            context: ?*anyopaque,
            seat: *wayland.client.river.SeatV1,
            focus: LayerShell.Focus,
        ) void {
            const self: *Manager = @ptrCast(@alignCast(context orelse return));
            if (self.hooks.on_layer_seat_focus) |hook|
                hook(self, seat, focus, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
        }

        fn beginManage(self: *Manager) void {
            if (self.state != .claimed) return;
            self.state = .managing;
            self.manage_starts += 1;
            if (self.layer_shell) |*layer_manager| {
                if (self.outputs.items.len != 0)
                    layer_manager.setDefaultOutput(self.outputs.items[0]);
                layer_manager.restoreWindowFocus();
            }
            runTransactionHook(self, .managing, self.hooks.on_manage_start, Manager.manageFinish);
        }

        fn beginRender(self: *Manager) void {
            if (self.state != .claimed) return;
            self.state = .rendering;
            self.render_starts += 1;
            runTransactionHook(self, .rendering, self.hooks.on_render_start, Manager.renderFinish);
        }

        fn runTransactionHook(self: *Manager, active: anytype, hook: anytype, finish: anytype) void {
            if (hook) |callback| {
                callback(self, self.hooks.context) catch |err| {
                    self.listener_error = err;
                    if (self.state == active) finish(self) catch |finish_err| {
                        self.listener_error = finish_err;
                    };
                };
                if (!self.hooks.defer_transactions and self.state == active) {
                    self.listener_error = error.InvalidState;
                    finish(self) catch |err| {
                        self.listener_error = err;
                    };
                }
            } else {
                finish(self) catch |err| {
                    self.listener_error = err;
                };
            }
        }

        fn runSessionHook(self: *Manager, hook: anytype) void {
            if (hook) |callback|
                callback(self, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
        }

        fn addWindow(self: *Manager, window: *wayland.client.river.WindowV1) void {
            const node = window.getNode() catch {
                self.listener_error = error.OutOfMemory;
                window.destroy();
                return;
            };
            self.nodes.append(self.allocator, node) catch {
                self.listener_error = error.OutOfMemory;
                node.destroy();
                window.destroy();
                return;
            };
            if (self.hooks.on_window_created) |hook|
                hook(self, window, node, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
            window.setListener(*Manager, onWindowEvent, self);
            self.windows.append(self.allocator, window) catch {
                self.listener_error = error.OutOfMemory;
                window.destroy();
            };
        }

        fn addOutput(self: *Manager, output: *wayland.client.river.OutputV1) void {
            if (self.layer_shell) |*layer_manager| layer_manager.addOutput(output) catch |err| {
                self.listener_error = err;
                output.destroy();
                return;
            };
            if (self.hooks.on_output_created) |hook|
                hook(self, output, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
            output.setListener(*Manager, onOutputEvent, self);
            self.outputs.append(self.allocator, output) catch {
                self.listener_error = error.OutOfMemory;
                if (self.layer_shell) |*layer_manager| layer_manager.removeOutput(output);
                output.destroy();
            };
        }

        fn addSeat(self: *Manager, seat: *wayland.client.river.SeatV1) void {
            if (self.layer_shell) |*layer_manager| layer_manager.addSeat(seat) catch |err| {
                self.listener_error = err;
                seat.destroy();
                return;
            };
            if (self.hooks.on_seat_created) |hook|
                hook(self, seat, self.hooks.context) catch |err| {
                    self.listener_error = err;
                };
            seat.setListener(*Manager, onSeatEvent, self);
            self.seats.append(self.allocator, seat) catch {
                self.listener_error = error.OutOfMemory;
                if (self.layer_shell) |*layer_manager| layer_manager.removeSeat(seat);
                seat.destroy();
            };
        }

        fn removeProxy(comptime Proxy: type, list: *std.ArrayList(*Proxy), target: *Proxy) void {
            for (list.items, 0..) |proxy, index| {
                if (proxy == target) {
                    _ = list.orderedRemove(index);
                    return;
                }
            }
        }
    };
}

const std = @import("std");
