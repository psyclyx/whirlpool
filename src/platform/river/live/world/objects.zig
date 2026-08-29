//! River proxy identities and their host/WM associations.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const wm = @import("whirlpool-wm");

const types = host.types;

pub const WindowRecord = struct {
    id: types.WindowId,
    node: types.NodeId,
    wm_id: ?wm.WindowId = null,
    preferred_output: ?types.OutputId = null,
    desired_placement: wm.Placement = .tiled,
    actual_size: ?types.Size = null,
    decoration_hint: ?types.DecorationHint = null,
    decoration_ssd_applied: ?bool = null,
    app_id: []u8 = &.{},
    title: []u8 = &.{},
    closed: bool = false,

    pub fn deinit(self: *WindowRecord, allocator: std.mem.Allocator) void {
        if (self.app_id.len != 0) allocator.free(self.app_id);
        if (self.title.len != 0) allocator.free(self.title);
        self.* = undefined;
    }
};

pub const OutputRecord = struct {
    id: types.OutputId,
    wm_id: ?wm.OutputId = null,
    tag: ?wm.TagId = null,
    owns_tag: bool = false,
    position: ?types.Point = null,
    dimensions: ?types.Size = null,
    usable: ?wm.Rect = null,
    removed: bool = false,
};

pub const LayerFocus = enum { exclusive, non_exclusive, none };
pub const SeatRecord = struct {
    layer_focus: LayerFocus = .none,
    applied_window_focus: ?wm.WindowId = null,
    focus_needs_reassert: bool = false,
};

pub const Counts = struct {
    windows: usize,
    outputs: usize,
    seats: usize,
    shell_surfaces: usize,
    decorations: usize,
    pointer_bindings: usize,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    maps: host.proxy_maps.ProxyMaps,
    windows: std.AutoHashMap(types.WindowId, WindowRecord),
    outputs: std.AutoHashMap(types.OutputId, OutputRecord),
    seats: std.AutoHashMap(types.SeatId, SeatRecord),
    window_order: std.ArrayList(types.WindowId) = .empty,
    output_order: std.ArrayList(types.OutputId) = .empty,
    wm_to_window: std.AutoHashMap(wm.WindowId, types.WindowId),
    wm_to_output: std.AutoHashMap(wm.OutputId, types.OutputId),
    next_window: u64 = 1,
    next_output: u64 = 1,
    next_seat: u64 = 1,
    next_shell_surface: u64 = 1,
    next_decoration: u64 = 1,
    next_pointer_binding: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .maps = .init(allocator),
            .windows = .init(allocator),
            .outputs = .init(allocator),
            .seats = .init(allocator),
            .wm_to_window = .init(allocator),
            .wm_to_output = .init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.wm_to_output.deinit();
        self.wm_to_window.deinit();
        self.output_order.deinit(self.allocator);
        self.window_order.deinit(self.allocator);
        self.seats.deinit();
        self.outputs.deinit();
        var windows = self.windows.valueIterator();
        while (windows.next()) |record| record.deinit(self.allocator);
        self.windows.deinit();
        self.maps.deinit();
        self.* = undefined;
    }

    pub fn counts(self: *const Registry) Counts {
        return .{
            .windows = self.windows.count(),
            .outputs = self.outputs.count(),
            .seats = self.seats.count(),
            .shell_surfaces = self.maps.shell_surfaces.count(),
            .decorations = self.maps.decorations.count(),
            .pointer_bindings = self.maps.pointer_bindings.count(),
        };
    }

    pub fn bindWindow(self: *Registry, window_proxy: types.ProxyRef, node_proxy: types.ProxyRef) !types.WindowId {
        if (self.maps.windows.idFor(window_proxy) != null or self.maps.nodes.idFor(node_proxy) != null)
            return error.DuplicateObject;
        const raw = try peekId(self.next_window);
        const id = types.WindowId.init(raw);
        const node = types.NodeId.init(raw);
        try self.maps.windows.bind(window_proxy, id);
        errdefer _ = self.maps.windows.unbindProxy(window_proxy) catch unreachable;
        try self.maps.nodes.bind(node_proxy, node);
        errdefer _ = self.maps.nodes.unbindProxy(node_proxy) catch unreachable;
        try self.windows.put(id, .{ .id = id, .node = node });
        errdefer std.debug.assert(self.windows.remove(id));
        try self.window_order.append(self.allocator, id);
        errdefer _ = self.window_order.pop();
        advanceId(&self.next_window);
        return id;
    }

    pub fn bindOutput(self: *Registry, proxy: types.ProxyRef) !types.OutputId {
        if (self.maps.outputs.idFor(proxy) != null) return error.DuplicateObject;
        const id = types.OutputId.init(try peekId(self.next_output));
        try self.maps.outputs.bind(proxy, id);
        errdefer _ = self.maps.outputs.unbindProxy(proxy) catch unreachable;
        try self.outputs.put(id, .{ .id = id });
        errdefer std.debug.assert(self.outputs.remove(id));
        try self.output_order.append(self.allocator, id);
        errdefer _ = self.output_order.pop();
        advanceId(&self.next_output);
        return id;
    }

    pub fn bindSeat(self: *Registry, proxy: types.ProxyRef) !types.SeatId {
        if (self.maps.seats.idFor(proxy) != null) return error.DuplicateObject;
        const id = types.SeatId.init(try peekId(self.next_seat));
        try self.maps.seats.bind(proxy, id);
        errdefer _ = self.maps.seats.unbindProxy(proxy) catch unreachable;
        try self.seats.put(id, .{});
        errdefer std.debug.assert(self.seats.remove(id));
        advanceId(&self.next_seat);
        return id;
    }

    pub fn bindShellSurface(self: *Registry, proxy: types.ProxyRef) !types.ShellSurfaceId {
        const id = types.ShellSurfaceId.init(try peekId(self.next_shell_surface));
        try self.maps.shell_surfaces.bind(proxy, id);
        advanceId(&self.next_shell_surface);
        return id;
    }

    pub fn bindDecoration(self: *Registry, proxy: types.ProxyRef) !types.DecorationId {
        const id = types.DecorationId.init(try peekId(self.next_decoration));
        try self.maps.decorations.bind(proxy, id);
        advanceId(&self.next_decoration);
        return id;
    }

    pub fn bindPointerBinding(self: *Registry, proxy: types.ProxyRef) !types.PointerBindingId {
        const id = types.PointerBindingId.init(try peekId(self.next_pointer_binding));
        try self.maps.pointer_bindings.bind(proxy, id);
        advanceId(&self.next_pointer_binding);
        return id;
    }

    pub fn unbindShellSurface(self: *Registry, proxy: types.ProxyRef) !types.ShellSurfaceId {
        return self.maps.shell_surfaces.unbindProxy(proxy) catch return error.UnknownShellSurface;
    }

    pub fn unbindDecoration(self: *Registry, proxy: types.ProxyRef) !types.DecorationId {
        return self.maps.decorations.unbindProxy(proxy) catch return error.UnknownDecoration;
    }

    pub fn unbindPointerBinding(self: *Registry, proxy: types.ProxyRef) !types.PointerBindingId {
        return self.maps.pointer_bindings.unbindProxy(proxy) catch return error.UnknownPointerBinding;
    }

    pub fn bindLiveWindow(self: *Registry, window: *wayland.client.river.WindowV1, node: *wayland.client.river.NodeV1) !types.WindowId {
        return self.bindWindow(proxyRef(window), proxyRef(node));
    }

    pub fn bindLiveOutput(self: *Registry, output: *wayland.client.river.OutputV1) !types.OutputId {
        return self.bindOutput(proxyRef(output));
    }

    pub fn bindLiveSeat(self: *Registry, seat: *wayland.client.river.SeatV1) !types.SeatId {
        return self.bindSeat(proxyRef(seat));
    }

    pub fn bindLiveShellSurface(self: *Registry, surface: *wayland.client.river.ShellSurfaceV1) !types.ShellSurfaceId {
        return self.bindShellSurface(proxyRef(surface));
    }

    pub fn bindLiveDecoration(self: *Registry, decoration: *wayland.client.river.DecorationV1) !types.DecorationId {
        return self.bindDecoration(proxyRef(decoration));
    }

    pub fn bindLivePointerBinding(self: *Registry, binding: *wayland.client.river.PointerBindingV1) !types.PointerBindingId {
        return self.bindPointerBinding(proxyRef(binding));
    }

    pub fn unbindLiveShellSurface(self: *Registry, surface: *wayland.client.river.ShellSurfaceV1) !types.ShellSurfaceId {
        return self.unbindShellSurface(proxyRef(surface));
    }

    pub fn unbindLiveDecoration(self: *Registry, decoration: *wayland.client.river.DecorationV1) !types.DecorationId {
        return self.unbindDecoration(proxyRef(decoration));
    }

    pub fn unbindLivePointerBinding(self: *Registry, binding: *wayland.client.river.PointerBindingV1) !types.PointerBindingId {
        return self.unbindPointerBinding(proxyRef(binding));
    }

    pub fn actualWindowSize(self: *const Registry, window: types.WindowId) !?types.Size {
        return (self.windows.get(window) orelse return error.UnknownWindow).actual_size;
    }

    pub fn windowRecord(self: *const Registry, window: types.WindowId) !*const WindowRecord {
        return self.windows.getPtr(window) orelse error.UnknownWindow;
    }

    pub fn setWindowAppId(self: *Registry, window: types.WindowId, value: []const u8) !void {
        const record = self.windows.getPtr(window) orelse return error.UnknownWindow;
        try replaceOwned(self.allocator, &record.app_id, value);
    }

    pub fn setWindowTitle(self: *Registry, window: types.WindowId, value: []const u8) !void {
        const record = self.windows.getPtr(window) orelse return error.UnknownWindow;
        try replaceOwned(self.allocator, &record.title, value);
    }

    pub fn outputSize(self: *const Registry, output: types.OutputId) !?types.Size {
        return (self.outputs.get(output) orelse return error.UnknownOutput).dimensions;
    }

    pub fn windowProxy(self: *const Registry, id: types.WindowId) !*wayland.client.river.WindowV1 {
        return proxyPointer(wayland.client.river.WindowV1, self.maps.windows.proxyFor(id) orelse return error.UnknownWindow);
    }

    pub fn wmWindowId(self: *const Registry, window: types.WindowId) !wm.WindowId {
        var iterator = self.wm_to_window.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.*.value == window.value) return entry.key_ptr.*;
        return error.UnknownWindow;
    }

    pub fn outputProxy(self: *const Registry, id: types.OutputId) !*wayland.client.river.OutputV1 {
        return proxyPointer(wayland.client.river.OutputV1, self.maps.outputs.proxyFor(id) orelse return error.UnknownOutput);
    }

    pub fn outputId(self: *const Registry, output: *wayland.client.river.OutputV1) !types.OutputId {
        return self.maps.outputs.idFor(proxyRef(output)) orelse error.UnknownOutput;
    }

    pub fn wmOutputId(self: *const Registry, output: types.OutputId) !wm.OutputId {
        return (self.outputs.get(output) orelse return error.UnknownOutput).wm_id orelse error.IncompleteOutput;
    }

    pub fn seatProxy(self: *const Registry, id: types.SeatId) !*wayland.client.river.SeatV1 {
        return proxyPointer(wayland.client.river.SeatV1, self.maps.seats.proxyFor(id) orelse return error.UnknownSeat);
    }

    pub fn nodeProxy(self: *const Registry, id: types.NodeId) !*wayland.client.river.NodeV1 {
        return proxyPointer(wayland.client.river.NodeV1, self.maps.nodes.proxyFor(id) orelse return error.UnknownNode);
    }

    pub fn shellSurfaceProxy(self: *const Registry, id: types.ShellSurfaceId) !*wayland.client.river.ShellSurfaceV1 {
        return proxyPointer(wayland.client.river.ShellSurfaceV1, self.maps.shell_surfaces.proxyFor(id) orelse return error.UnknownShellSurface);
    }

    pub fn shellSurfaceId(self: *const Registry, surface: *wayland.client.river.ShellSurfaceV1) !types.ShellSurfaceId {
        return self.maps.shell_surfaces.idFor(proxyRef(surface)) orelse error.UnknownShellSurface;
    }

    pub fn decorationProxy(self: *const Registry, id: types.DecorationId) !*wayland.client.river.DecorationV1 {
        return proxyPointer(wayland.client.river.DecorationV1, self.maps.decorations.proxyFor(id) orelse return error.UnknownDecoration);
    }

    pub fn decorationId(self: *const Registry, decoration: *wayland.client.river.DecorationV1) !types.DecorationId {
        return self.maps.decorations.idFor(proxyRef(decoration)) orelse error.UnknownDecoration;
    }

    pub fn pointerBindingProxy(self: *const Registry, id: types.PointerBindingId) !*wayland.client.river.PointerBindingV1 {
        return proxyPointer(wayland.client.river.PointerBindingV1, self.maps.pointer_bindings.proxyFor(id) orelse return error.UnknownPointerBinding);
    }
};

fn replaceOwned(allocator: std.mem.Allocator, destination: *[]u8, value: []const u8) !void {
    if (value.len == 0) {
        if (destination.*.len != 0) allocator.free(destination.*);
        destination.* = &.{};
        return;
    }
    const replacement = try allocator.dupe(u8, value);
    if (destination.*.len != 0) allocator.free(destination.*);
    destination.* = replacement;
}

fn peekId(next: u64) !u64 {
    if (next == 0) return error.IdExhausted;
    return next;
}

fn advanceId(next: *u64) void {
    next.* +%= 1;
}

pub fn proxyRef(proxy: anytype) types.ProxyRef {
    return types.ProxyRef.init(@intFromPtr(proxy)) catch unreachable;
}

fn proxyPointer(comptime Proxy: type, reference: types.ProxyRef) *Proxy {
    return @ptrFromInt(reference.value);
}
