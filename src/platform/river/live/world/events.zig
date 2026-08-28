//! River child-event decoding into transport-neutral host facts and intents.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const live_objects = @import("objects.zig");

const types = host.types;

pub const Area = struct { x: i32, y: i32, width: i32, height: i32 };

pub fn onWindow(self: anytype, window: *wayland.client.river.WindowV1, event: wayland.client.river.WindowV1.Event) !void {
    const proxy = live_objects.proxyRef(window);
    const id = self.objects.maps.windows.idFor(proxy) orelse return error.UnknownWindow;
    switch (event) {
        .closed => _ = try self.closeWindowRef(proxy),
        .dimensions_hint,
        .decoration_hint,
        .unreliable_pid,
        .presentation_hint,
        .identifier,
        .capture_sessions,
        => {},
        .app_id => |value| try self.objects.setWindowAppId(id, if (value.app_id) |text| std.mem.span(text) else ""),
        .title => |value| try self.objects.setWindowTitle(id, if (value.title) |text| std.mem.span(text) else ""),
        .dimensions => |value| try self.stageRenderFact(.{ .window_dimensions = .{
            .window = id,
            .size = .{ .width = value.width, .height = value.height },
        } }),
        .parent => |value| if (value.parent) |parent| {
            _ = self.objects.maps.windows.idFor(live_objects.proxyRef(parent)) orelse return error.UnknownWindow;
        },
        .pointer_move_requested => |value| _ = try requiredSeat(self, value.seat),
        .pointer_resize_requested => |value| _ = try requiredSeat(self, value.seat),
        .show_window_menu_requested => |value| try validateWindowMenuRequest(self, id, .{ .x = value.x, .y = value.y }),
        .maximize_requested => try self.stageManageFact(.{ .window_maximize_requested = id }),
        .unmaximize_requested => try self.stageManageFact(.{ .window_unmaximize_requested = id }),
        .fullscreen_requested => |value| try self.stageManageFact(.{ .window_fullscreen_requested = .{
            .window = id,
            .output = if (value.output) |output|
                self.objects.maps.outputs.idFor(live_objects.proxyRef(output)) orelse return error.UnknownOutput
            else
                null,
        } }),
        .exit_fullscreen_requested => try self.stageManageFact(.{ .window_exit_fullscreen_requested = id }),
        .minimize_requested => try self.stageManageFact(.{ .window_minimize_requested = id }),
    }
}

pub fn onOutput(self: anytype, output: *wayland.client.river.OutputV1, event: wayland.client.river.OutputV1.Event) !void {
    const proxy = live_objects.proxyRef(output);
    const id = self.objects.maps.outputs.idFor(proxy) orelse return error.UnknownOutput;
    switch (event) {
        .removed => _ = try self.removeOutputRef(proxy),
        .wl_output, .capture_sessions => {},
        .position => |value| try self.stageManageFact(.{ .output_position = .{
            .output = id,
            .position = .{ .x = value.x, .y = value.y },
        } }),
        .dimensions => |value| try self.stageManageFact(.{ .output_dimensions = .{
            .output = id,
            .size = .{ .width = value.width, .height = value.height },
        } }),
    }
}

pub fn onLayerOutputArea(self: anytype, output: *wayland.client.river.OutputV1, area: Area) !void {
    if (area.width < 0 or area.height < 0) return error.InvalidDimensions;
    const id = self.objects.maps.outputs.idFor(live_objects.proxyRef(output)) orelse return error.UnknownOutput;
    self.objects.outputs.getPtr(id).?.usable = .{
        .x = area.x,
        .y = area.y,
        .width = @intCast(area.width),
        .height = @intCast(area.height),
    };
}

pub fn onLayerSeatFocus(self: anytype, seat: *wayland.client.river.SeatV1, focus: live_objects.LayerFocus) !void {
    const id = self.objects.maps.seats.idFor(live_objects.proxyRef(seat)) orelse return error.UnknownSeat;
    self.objects.seats.getPtr(id).?.layer_focus = focus;
}

pub fn onSeat(self: anytype, seat: *wayland.client.river.SeatV1, event: wayland.client.river.SeatV1.Event) !void {
    const proxy = live_objects.proxyRef(seat);
    const id = self.objects.maps.seats.idFor(proxy) orelse return error.UnknownSeat;
    switch (event) {
        .removed => _ = try self.removeSeatRef(proxy),
        .wl_seat, .pointer_leave, .op_delta, .op_release, .pointer_position => {},
        .pointer_enter => |value| _ = try requiredWindow(self, value.window),
        .window_interaction => |value| try self.stageManageFact(.{ .seat_window_interaction = .{
            .seat = id,
            .window = try requiredWindow(self, value.window),
        } }),
        .shell_surface_interaction => |value| _ = try requiredShellSurface(self, value.shell_surface),
    }
}

pub fn onPointerBinding(self: anytype, binding: *wayland.client.river.PointerBindingV1, event: wayland.client.river.PointerBindingV1.Event) !void {
    const id = self.objects.maps.pointer_bindings.idFor(live_objects.proxyRef(binding)) orelse return error.UnknownPointerBinding;
    switch (event) {
        .pressed => try self.stagePointerBindingIntent(id, true),
        .released => try self.stagePointerBindingIntent(id, false),
    }
}

fn requiredWindow(self: anytype, maybe: ?*wayland.client.river.WindowV1) !types.WindowId {
    const proxy = maybe orelse return error.NullProtocolObject;
    return self.objects.maps.windows.idFor(live_objects.proxyRef(proxy)) orelse error.UnknownWindow;
}

fn requiredSeat(self: anytype, maybe: ?*wayland.client.river.SeatV1) !types.SeatId {
    const proxy = maybe orelse return error.NullProtocolObject;
    return self.objects.maps.seats.idFor(live_objects.proxyRef(proxy)) orelse error.UnknownSeat;
}

fn requiredShellSurface(self: anytype, maybe: ?*wayland.client.river.ShellSurfaceV1) !types.ShellSurfaceId {
    const proxy = maybe orelse return error.NullProtocolObject;
    return self.objects.maps.shell_surfaces.idFor(live_objects.proxyRef(proxy)) orelse error.UnknownShellSurface;
}

fn validateWindowMenuRequest(self: anytype, window: types.WindowId, position: types.Point) !void {
    const resolver = self.options.menu_seat orelse return;
    const seat = try resolver.resolve(resolver.context, window, position) orelse return error.MissingMenuSeat;
    if (!self.objects.seats.contains(seat)) return error.UnknownSeat;
}
