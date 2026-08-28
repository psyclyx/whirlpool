//! Generated River listener edge. Callbacks only stage facts and boundaries.

const wayland = @import("wayland");
const host = @import("whirlpool-host");
const live = @import("whirlpool-river-live");
const world = @import("whirlpool-river-live-world");

const coordinator = host.river_coordinator;

pub fn hooks(comptime Runtime: type) live.Hooks {
    const C = Callbacks(Runtime);
    return .{
        .defer_transactions = true,
        .on_manage_start = C.onManageStart,
        .on_render_start = C.onRenderStart,
        .on_window_created = C.onWindowCreated,
        .on_output_created = C.onOutputCreated,
        .on_seat_created = C.onSeatCreated,
        .on_shell_surface_created = C.onShellSurfaceCreated,
        .on_decoration_created = C.onDecorationCreated,
        .on_pointer_binding_created = C.onPointerBindingCreated,
        .on_window_event = C.onWindowEvent,
        .on_output_event = C.onOutputEvent,
        .on_seat_event = C.onSeatEvent,
        .on_layer_output_area = C.onLayerOutputArea,
        .on_layer_seat_focus = C.onLayerSeatFocus,
        .on_pointer_binding_event = C.onPointerBindingEvent,
        .on_shell_surface_destroyed = C.onShellSurfaceDestroyed,
        .on_decoration_destroyed = C.onDecorationDestroyed,
        .on_pointer_binding_destroyed = C.onPointerBindingDestroyed,
    };
}

fn Callbacks(comptime Runtime: type) type {
    return struct {
        fn from(raw: ?*anyopaque) *Runtime {
            return @ptrCast(@alignCast(raw orelse unreachable));
        }

        fn enter(self: *Runtime) !void {
            if (self.callback_depth != 0) return error.NestedProtocolCallback;
            self.callback_depth = 1;
        }

        fn setBoundary(self: *Runtime, boundary: anytype) !void {
            if (self.boundary != .none) return error.BoundaryAlreadyPending;
            self.boundary = boundary;
        }

        fn onManageStart(_: *live.Manager, raw: ?*anyopaque) anyerror!void {
            const self = from(raw);
            try enter(self);
            defer self.callback_depth = 0;
            if (self.options.manage) |hook| try hook.run(hook.context);
            try setBoundary(self, .manage);
        }

        fn onRenderStart(_: *live.Manager, raw: ?*anyopaque) anyerror!void {
            const self = from(raw);
            try enter(self);
            defer self.callback_depth = 0;
            try setBoundary(self, .render);
        }

        fn onWindowCreated(_: *live.Manager, proxy: *wayland.client.river.WindowV1, node: *wayland.client.river.NodeV1, raw: ?*anyopaque) anyerror!void {
            _ = try from(raw).adapter.objects.bindLiveWindow(proxy, node);
        }
        fn onOutputCreated(_: *live.Manager, proxy: *wayland.client.river.OutputV1, raw: ?*anyopaque) anyerror!void {
            _ = try from(raw).adapter.objects.bindLiveOutput(proxy);
        }
        fn onSeatCreated(_: *live.Manager, proxy: *wayland.client.river.SeatV1, raw: ?*anyopaque) anyerror!void {
            const self = from(raw);
            _ = try self.adapter.objects.bindLiveSeat(proxy);
            if (self.options.seat) |hook| try hook.run(hook.context, proxy);
        }
        fn onShellSurfaceCreated(_: *live.Manager, proxy: *wayland.client.river.ShellSurfaceV1, raw: ?*anyopaque) anyerror!void {
            _ = try from(raw).adapter.objects.bindLiveShellSurface(proxy);
        }
        fn onDecorationCreated(_: *live.Manager, proxy: *wayland.client.river.DecorationV1, raw: ?*anyopaque) anyerror!void {
            _ = try from(raw).adapter.objects.bindLiveDecoration(proxy);
        }
        fn onPointerBindingCreated(_: *live.Manager, proxy: *wayland.client.river.PointerBindingV1, raw: ?*anyopaque) anyerror!void {
            _ = try from(raw).adapter.objects.bindLivePointerBinding(proxy);
        }
        fn onWindowEvent(_: *live.Manager, proxy: *wayland.client.river.WindowV1, event: wayland.client.river.WindowV1.Event, raw: ?*anyopaque) anyerror!void {
            try world.events.onWindow(&from(raw).adapter, proxy, event);
        }
        fn onOutputEvent(_: *live.Manager, proxy: *wayland.client.river.OutputV1, event: wayland.client.river.OutputV1.Event, raw: ?*anyopaque) anyerror!void {
            try world.events.onOutput(&from(raw).adapter, proxy, event);
        }
        fn onSeatEvent(_: *live.Manager, proxy: *wayland.client.river.SeatV1, event: wayland.client.river.SeatV1.Event, raw: ?*anyopaque) anyerror!void {
            try world.events.onSeat(&from(raw).adapter, proxy, event);
        }
        fn onLayerOutputArea(_: *live.Manager, proxy: *wayland.client.river.OutputV1, area: live.LayerShell.Area, raw: ?*anyopaque) anyerror!void {
            try world.events.onLayerOutputArea(&from(raw).adapter, proxy, .{ .x = area.x, .y = area.y, .width = area.width, .height = area.height });
        }
        fn onLayerSeatFocus(_: *live.Manager, proxy: *wayland.client.river.SeatV1, focus: live.LayerShell.Focus, raw: ?*anyopaque) anyerror!void {
            const translated: world.LayerFocus = switch (focus) {
                .exclusive => .exclusive,
                .non_exclusive => .non_exclusive,
                .none => .none,
            };
            try world.events.onLayerSeatFocus(&from(raw).adapter, proxy, translated);
        }
        fn onPointerBindingEvent(_: *live.Manager, proxy: *wayland.client.river.PointerBindingV1, event: wayland.client.river.PointerBindingV1.Event, raw: ?*anyopaque) anyerror!void {
            try world.events.onPointerBinding(&from(raw).adapter, proxy, event);
        }
        fn onShellSurfaceDestroyed(_: *live.Manager, proxy: *wayland.client.river.ShellSurfaceV1, raw: ?*anyopaque) anyerror!void {
            const self = from(raw);
            const id = self.adapter.objects.unbindLiveShellSurface(proxy) catch return;
            cancelRole(self, .{ .shell = id });
        }
        fn onDecorationDestroyed(_: *live.Manager, proxy: *wayland.client.river.DecorationV1, raw: ?*anyopaque) anyerror!void {
            const self = from(raw);
            const id = self.adapter.objects.unbindLiveDecoration(proxy) catch return;
            cancelRole(self, .{ .decoration = id });
        }
        fn onPointerBindingDestroyed(_: *live.Manager, proxy: *wayland.client.river.PointerBindingV1, raw: ?*anyopaque) anyerror!void {
            _ = from(raw).adapter.objects.unbindLivePointerBinding(proxy) catch return;
        }

        fn cancelRole(self: *Runtime, role: coordinator.SurfaceRole) void {
            self.surface_queue.cancel(role);
        }
    };
}
