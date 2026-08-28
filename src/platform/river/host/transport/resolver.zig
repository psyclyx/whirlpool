//! Resolution of host identities to live River protocol objects.

const wayland = @import("wayland");
const host = @import("whirlpool-host");
const plans = @import("whirlpool-river-live-plans");

const types = host.types;

/// Build a resolver backed by runtime's live-object registry.
pub fn init(comptime Runtime: type, runtime: *Runtime) plans.Resolver {
    return .{
        .context = runtime,
        .window = proxyCallback(Runtime, types.WindowId, *wayland.client.river.WindowV1, "windowProxy"),
        .node = proxyCallback(Runtime, types.NodeId, *wayland.client.river.NodeV1, "nodeProxy"),
        .seat = proxyCallback(Runtime, types.SeatId, *wayland.client.river.SeatV1, "seatProxy"),
        .output = proxyCallback(Runtime, types.OutputId, *wayland.client.river.OutputV1, "outputProxy"),
        .shell_surface = proxyCallback(Runtime, types.ShellSurfaceId, *wayland.client.river.ShellSurfaceV1, "shellSurfaceProxy"),
        .decoration = proxyCallback(Runtime, types.DecorationId, *wayland.client.river.DecorationV1, "decorationProxy"),
        .pointer_binding = proxyCallback(Runtime, types.PointerBindingId, *wayland.client.river.PointerBindingV1, "pointerBindingProxy"),
    };
}

fn runtimeFrom(comptime Runtime: type, raw: *anyopaque) *Runtime {
    return @ptrCast(@alignCast(raw));
}

fn proxyCallback(
    comptime Runtime: type,
    comptime Id: type,
    comptime Proxy: type,
    comptime method: []const u8,
) *const fn (*anyopaque, Id) anyerror!Proxy {
    return struct {
        fn call(raw: *anyopaque, id: Id) anyerror!Proxy {
            const objects = &runtimeFrom(Runtime, raw).adapter.objects;
            return @field(@TypeOf(objects.*), method)(objects, id);
        }
    }.call;
}
