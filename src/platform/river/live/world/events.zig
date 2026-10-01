//! River child-event decoding into transport-neutral host facts and intents.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const live_objects = @import("objects.zig");
const wm = @import("whirlpool-wm");

const types = host.types;

pub const Area = struct { x: i32, y: i32, width: i32, height: i32 };

pub fn onWindow(self: anytype, window: *wayland.client.river.WindowV1, event: wayland.client.river.WindowV1.Event) !void {
    const proxy = live_objects.proxyRef(window);
    const id = self.objects.maps.windows.idFor(proxy) orelse return error.UnknownWindow;
    switch (event) {
        .closed => _ = try self.closeWindowRef(proxy),
        .unreliable_pid => |value| if (value.unreliable_pid > 0) {
            self.objects.windows.getPtr(id).?.pid = value.unreliable_pid;
            self.objects.metadata_revision +%= 1;
        },
        .presentation_hint,
        .capture_sessions,
        => {},
        .identifier => |value| self.objects.windows.getPtr(id).?.identifier = wm.Identifier.init(std.mem.span(value.identifier)),
        .dimensions_hint => |value| {
            if (value.min_width < 0 or value.min_height < 0 or value.max_width < 0 or value.max_height < 0)
                return error.InvalidDimensions;
            if ((value.max_width != 0 and value.min_width > value.max_width) or
                (value.max_height != 0 and value.min_height > value.max_height))
                return error.InvalidDimensions;
            try self.objects.setWindowDimensionsHint(id, .{
                .min = .{ .width = @intCast(value.min_width), .height = @intCast(value.min_height) },
                .max = .{ .width = @intCast(value.max_width), .height = @intCast(value.max_height) },
            });
        },
        .decoration_hint => |value| self.objects.windows.getPtr(id).?.decoration_hint =
            @enumFromInt(@as(u32, @intCast(@intFromEnum(value.hint)))),
        .app_id => |value| try self.objects.setWindowAppId(id, if (value.app_id) |text| std.mem.span(text) else ""),
        .title => |value| try self.objects.setWindowTitle(id, if (value.title) |text| std.mem.span(text) else ""),
        .dimensions => |value| try self.stageRenderFact(.{ .window_dimensions = .{
            .window = id,
            .size = .{ .width = value.width, .height = value.height },
        } }),
        .parent => |value| try self.objects.setWindowParent(id, if (value.parent) |parent|
            self.objects.maps.windows.idFor(live_objects.proxyRef(parent)) orelse return error.UnknownWindow
        else
            null),
        .pointer_move_requested => |value| try beginPointerOperation(self, id, try requiredSeat(self, value.seat), .move, null),
        .pointer_resize_requested => |value| try beginPointerOperation(self, id, try requiredSeat(self, value.seat), .resize, @as(u32, @bitCast(value.edges))),
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
    const record = self.objects.seats.getPtr(id).?;
    if (record.layer_focus == .exclusive and focus != .exclusive)
        record.focus_needs_reassert = true;
    record.layer_focus = focus;
}

pub fn onSeat(self: anytype, seat: *wayland.client.river.SeatV1, event: wayland.client.river.SeatV1.Event) !void {
    const proxy = live_objects.proxyRef(seat);
    const id = self.objects.maps.seats.idFor(proxy) orelse return error.UnknownSeat;
    switch (event) {
        .removed => _ = try self.removeSeatRef(proxy),
        .wl_seat, .pointer_leave, .pointer_position => {},
        .op_delta => |value| try updatePointerOperation(self, id, .{ .x = value.dx, .y = value.dy }),
        .op_release => markPointerOperationReleased(self, id),
        .pointer_enter => |value| _ = try requiredWindow(self, value.window),
        .window_interaction => |value| try self.stageManageFact(.{ .seat_window_interaction = .{
            .seat = id,
            .window = try requiredWindow(self, value.window),
        } }),
        .shell_surface_interaction => |value| _ = try requiredShellSurface(self, value.shell_surface),
    }
}

fn beginPointerOperation(self: anytype, window: types.WindowId, seat: types.SeatId, kind: live_objects.PointerOperationKind, edges: ?u32) !void {
    const record = self.objects.windows.getPtr(window) orelse return error.UnknownWindow;
    record.requested_placement = .floating;
    self.objects.seats.getPtr(seat).?.operation = .{ .window = window, .kind = kind, .edges = edges };
}

fn updatePointerOperation(self: anytype, seat: types.SeatId, total: types.Point) !void {
    const seat_record = self.objects.seats.getPtr(seat) orelse return error.UnknownSeat;
    if (seat_record.operation == null) return;
    const operation = &seat_record.operation.?;
    const delta = types.Point{
        .x = try std.math.sub(i32, total.x, operation.last_delta.x),
        .y = try std.math.sub(i32, total.y, operation.last_delta.y),
    };
    operation.last_delta = total;
    try self.input_queue.append(.{
        .action = if (operation.kind == .move) .move else .resize,
        .source = .{ .window_request = operation.window },
        .seat = seat,
        .window = operation.window,
        .delta = delta,
        .edges = operation.edges,
    });
}

fn markPointerOperationReleased(self: anytype, seat: types.SeatId) void {
    const record = self.objects.seats.getPtr(seat) orelse return;
    if (record.operation) |*operation| operation.end_pending = true;
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

test "pointer operations emit incremental geometry intents and explicit lifetime requests" {
    const world = @import("root.zig");
    var adapter = world.Adapter.init(std.testing.allocator, .{});
    defer adapter.deinit();
    const window = try adapter.objects.bindWindow(try .init(0x1000), try .init(0x1001));
    const seat = try adapter.objects.bindSeat(try .init(0x2000));

    try beginPointerOperation(&adapter, window, seat, .resize, 0x5);
    try std.testing.expectEqual(@import("whirlpool-wm").Placement.floating, adapter.objects.windows.get(window).?.requested_placement.?);
    var operations = std.ArrayList(types.ManageOperation).empty;
    defer operations.deinit(std.testing.allocator);
    try adapter.appendPointerOperationRequests(&operations);
    try std.testing.expectEqual(@as(usize, 1), operations.items.len);
    try std.testing.expectEqual(seat, operations.items[0].op_start_pointer);
    adapter.commitPointerOperationRequests();

    try updatePointerOperation(&adapter, seat, .{ .x = 10, .y = 20 });
    try updatePointerOperation(&adapter, seat, .{ .x = 15, .y = 18 });
    const intents = try adapter.takeInputIntents();
    defer std.testing.allocator.free(intents);
    try std.testing.expectEqual(@as(usize, 2), intents.len);
    try std.testing.expectEqual(types.Point{ .x = 10, .y = 20 }, intents[0].delta);
    try std.testing.expectEqual(types.Point{ .x = 5, .y = -2 }, intents[1].delta);
    try std.testing.expectEqual(@as(?u32, 0x5), intents[1].edges);

    markPointerOperationReleased(&adapter, seat);
    operations.clearRetainingCapacity();
    try adapter.appendPointerOperationRequests(&operations);
    try std.testing.expectEqual(@as(usize, 1), operations.items.len);
    try std.testing.expectEqual(seat, operations.items[0].op_end);
    adapter.commitPointerOperationRequests();
    try std.testing.expect(adapter.objects.seats.get(seat).?.operation == null);
}
