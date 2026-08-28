//! Bidirectional maps between concrete Wayland proxy identities and River IDs.

const std = @import("std");
const types = @import("../types.zig");

pub fn ProxyMap(comptime IdType: type) type {
    return struct {
        const Self = @This();

        by_proxy: std.AutoHashMap(types.ProxyRef, IdType),
        by_id: std.AutoHashMap(IdType, types.ProxyRef),

        /// Initialize an empty proxy-to-ID bijection.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .by_proxy = .init(allocator),
                .by_id = .init(allocator),
            };
        }

        /// Release both indexes.
        pub fn deinit(self: *Self) void {
            self.assertValid();
            self.by_proxy.deinit();
            self.by_id.deinit();
            self.* = undefined;
        }

        /// Return the number of bound pairs.
        pub fn count(self: *const Self) usize {
            self.assertValid();
            return self.by_proxy.count();
        }

        /// Bind only when both identities are unused. The two indexes change
        /// atomically even if allocating the reverse index fails.
        pub fn bind(self: *Self, proxy: types.ProxyRef, id: IdType) !void {
            self.assertValid();
            if (self.by_proxy.contains(proxy)) return error.ProxyAlreadyBound;
            if (self.by_id.contains(id)) return error.IdAlreadyBound;

            try self.by_proxy.put(proxy, id);
            errdefer _ = self.by_proxy.remove(proxy);
            try self.by_id.put(id, proxy);
            self.assertValid();
            std.debug.assert(std.meta.eql(self.idFor(proxy).?, id));
        }

        /// Resolve a proxy identity to its host ID.
        pub fn idFor(self: *const Self, proxy: types.ProxyRef) ?IdType {
            self.assertValid();
            return self.by_proxy.get(proxy);
        }

        /// Resolve a host ID to its proxy identity.
        pub fn proxyFor(self: *const Self, id: IdType) ?types.ProxyRef {
            self.assertValid();
            return self.by_id.get(id);
        }

        /// Remove a pair by proxy identity.
        pub fn unbindProxy(self: *Self, proxy: types.ProxyRef) !IdType {
            self.assertValid();
            const id = self.by_proxy.get(proxy) orelse return error.UnknownProxy;
            std.debug.assert(self.by_proxy.remove(proxy));
            std.debug.assert(self.by_id.remove(id));
            self.assertValid();
            return id;
        }

        /// Remove a pair by host ID.
        pub fn unbindId(self: *Self, id: IdType) !types.ProxyRef {
            self.assertValid();
            const proxy = self.by_id.get(id) orelse return error.UnknownId;
            std.debug.assert(self.by_id.remove(id));
            std.debug.assert(self.by_proxy.remove(proxy));
            self.assertValid();
            return proxy;
        }

        fn assertValid(self: *const Self) void {
            if (!std.debug.runtime_safety) return;
            std.debug.assert(self.by_proxy.count() == self.by_id.count());
            var iterator = self.by_proxy.iterator();
            while (iterator.next()) |entry| {
                const reverse = self.by_id.get(entry.value_ptr.*) orelse unreachable;
                std.debug.assert(std.meta.eql(reverse, entry.key_ptr.*));
            }
        }
    };
}

pub const ProxyMaps = struct {
    windows: ProxyMap(types.WindowId),
    outputs: ProxyMap(types.OutputId),
    seats: ProxyMap(types.SeatId),
    nodes: ProxyMap(types.NodeId),
    shell_surfaces: ProxyMap(types.ShellSurfaceId),
    decorations: ProxyMap(types.DecorationId),
    pointer_bindings: ProxyMap(types.PointerBindingId),

    /// Initialize all independent River proxy identity spaces.
    pub fn init(allocator: std.mem.Allocator) ProxyMaps {
        return .{
            .windows = .init(allocator),
            .outputs = .init(allocator),
            .seats = .init(allocator),
            .nodes = .init(allocator),
            .shell_surfaces = .init(allocator),
            .decorations = .init(allocator),
            .pointer_bindings = .init(allocator),
        };
    }

    /// Release all proxy identity spaces.
    pub fn deinit(self: *ProxyMaps) void {
        self.windows.deinit();
        self.outputs.deinit();
        self.seats.deinit();
        self.nodes.deinit();
        self.shell_surfaces.deinit();
        self.decorations.deinit();
        self.pointer_bindings.deinit();
        self.* = undefined;
    }
};

test "proxy maps preserve bijections and reject aliases" {
    var maps = ProxyMaps.init(std.testing.allocator);
    defer maps.deinit();

    const proxy_a = try types.ProxyRef.init(0x1000);
    const proxy_b = try types.ProxyRef.init(0x2000);
    const window_a = types.WindowId.init(1);
    const window_b = types.WindowId.init(2);

    try maps.windows.bind(proxy_a, window_a);
    try std.testing.expectEqual(window_a, maps.windows.idFor(proxy_a).?);
    try std.testing.expectEqual(proxy_a, maps.windows.proxyFor(window_a).?);
    try std.testing.expectError(error.ProxyAlreadyBound, maps.windows.bind(proxy_a, window_b));
    try std.testing.expectError(error.IdAlreadyBound, maps.windows.bind(proxy_b, window_a));
    try std.testing.expectEqual(@as(usize, 1), maps.windows.count());

    try std.testing.expectEqual(window_a, try maps.windows.unbindProxy(proxy_a));
    try std.testing.expectEqual(@as(usize, 0), maps.windows.count());
    try std.testing.expectError(error.UnknownProxy, maps.windows.unbindProxy(proxy_a));
}

test "proxy kinds have independent identity spaces" {
    var maps = ProxyMaps.init(std.testing.allocator);
    defer maps.deinit();

    const window_proxy = try types.ProxyRef.init(7);
    const output_proxy = try types.ProxyRef.init(8);
    try maps.windows.bind(window_proxy, types.WindowId.init(1));
    try maps.outputs.bind(output_proxy, types.OutputId.init(1));

    try std.testing.expectEqual(types.WindowId.init(1), maps.windows.idFor(window_proxy).?);
    try std.testing.expectEqual(types.OutputId.init(1), maps.outputs.idFor(output_proxy).?);
}

fn bindWithFailingAllocator(allocator: std.mem.Allocator) !void {
    var maps = ProxyMaps.init(allocator);
    defer maps.deinit();

    maps.windows.bind(
        try types.ProxyRef.init(0x3000),
        types.WindowId.init(3),
    ) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), maps.windows.count());
        return err;
    };
}

test "proxy bind is atomic under every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        bindWithFailingAllocator,
        .{},
    );
}
