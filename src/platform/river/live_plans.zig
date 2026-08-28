//! Apply host River plans to generated river_window_manager_v1 proxies.
//!
//! This is the narrow platform seam between the host's typed plans and the
//! generated Wayland API.  The host supplies identities and operations; this
//! module supplies proxy lookup, request encoding, and sequence completion.
//! Proxy ownership remains with the caller of Resolver.  In particular, a
//! resolver must not create or destroy a proxy while resolving an operation.

const std = @import("std");
const wayland = @import("wayland");
const host = @import("whirlpool-host");
const live = @import("whirlpool-river-live");

const types = host.types;

pub const Error = error{
    InvalidSequencePhase,
    MissingResolver,
    MissingPointerBindingResolver,
};

/// The generated River proxy associated with each host identity.
///
/// The callbacks are deliberately typed at their boundary.  A platform map
/// can therefore keep its storage and lifetime policy private while the plan
/// applier never falls back to integer proxy IDs or untyped pointer casts.
/// `pointer_binding` is included because the host plan vocabulary contains
/// enable/disable operations for that generated object as well.
pub const Resolver = struct {
    context: *anyopaque,
    window: *const fn (*anyopaque, types.WindowId) anyerror!*wayland.client.river.WindowV1,
    node: *const fn (*anyopaque, types.NodeId) anyerror!*wayland.client.river.NodeV1,
    seat: *const fn (*anyopaque, types.SeatId) anyerror!*wayland.client.river.SeatV1,
    output: *const fn (*anyopaque, types.OutputId) anyerror!*wayland.client.river.OutputV1,
    shell_surface: *const fn (*anyopaque, types.ShellSurfaceId) anyerror!*wayland.client.river.ShellSurfaceV1,
    decoration: *const fn (*anyopaque, types.DecorationId) anyerror!*wayland.client.river.DecorationV1,
    pointer_binding: ?*const fn (*anyopaque, types.PointerBindingId) anyerror!*wayland.client.river.PointerBindingV1 = null,
};

pub const SequencePhase = enum {
    managing,
    rendering,
};

/// A transport is the smallest executable contract needed by the plan
/// runner.  The live adapter below supplies generated-proxy request hooks;
/// tests and fixtures can supply a trace hook without constructing Wayland
/// objects.  A transport's resolver is borrowed for the duration of one
/// apply call and is never retained by this module.
pub const Transport = struct {
    phase: SequencePhase,
    context: *anyopaque,
    resolver: ?Resolver,
    emit_manage: *const fn (*anyopaque, ?*const Resolver, types.ManageOperation) anyerror!void,
    emit_render: *const fn (*anyopaque, ?*const Resolver, types.RenderOperation) anyerror!void,
    finish_manage: *const fn (*anyopaque) anyerror!void,
    finish_render: *const fn (*anyopaque) anyerror!void,
};

/// Apply one host manage plan to a live `Manager` in its manage_start phase.
/// Exactly one manage_finish request is attempted after the operation loop,
/// including when resolution or another request hook fails.
pub fn applyManage(
    manager: *live.Manager,
    resolver: Resolver,
    plan: types.ManagePlan,
) anyerror!void {
    if (manager.state != .managing) return error.InvalidSequencePhase;
    return applyManageTransport(liveTransport(manager, resolver, .managing), plan);
}

/// Apply one host render plan to a live `Manager` in its render_start phase.
/// Exactly one render_finish request is attempted after the operation loop,
/// including when resolution or another request hook fails.
pub fn applyRender(
    manager: *live.Manager,
    resolver: Resolver,
    plan: types.RenderPlan,
) anyerror!void {
    if (manager.state != .rendering) return error.InvalidSequencePhase;
    return applyRenderTransport(liveTransport(manager, resolver, .rendering), plan);
}

pub fn liveTransport(manager: *live.Manager, resolver: Resolver, phase: SequencePhase) Transport {
    return .{
        .phase = phase,
        .context = @ptrCast(manager),
        .resolver = resolver,
        .emit_manage = emitManageProxy,
        .emit_render = emitRenderProxy,
        .finish_manage = finishManageProxy,
        .finish_render = finishRenderProxy,
    };
}

/// Execute a manage plan through an injected transport.  This is public so a
/// host integration can add a transport-level observer without duplicating
/// the completion invariant; normal live use should call `applyManage`.
pub fn applyManageTransport(transport: Transport, plan: types.ManagePlan) anyerror!void {
    if (transport.phase != .managing) return error.InvalidSequencePhase;

    var operation_error: ?anyerror = null;
    for (plan.operations) |operation| {
        emitManage(transport, operation) catch |err| {
            operation_error = err;
            break;
        };
    }

    // Finish is intentionally outside the catch above.  It is attempted for
    // every operation failure, and a failure to finish takes precedence: the
    // compositor cannot legally advance to its next sequence in that case.
    try transport.finish_manage(transport.context);
    if (operation_error) |err| return err;
}

/// Render counterpart to `applyManageTransport`.
pub fn applyRenderTransport(transport: Transport, plan: types.RenderPlan) anyerror!void {
    if (transport.phase != .rendering) return error.InvalidSequencePhase;

    var operation_error: ?anyerror = null;
    for (plan.operations) |operation| {
        emitRender(transport, operation) catch |err| {
            operation_error = err;
            break;
        };
    }

    try transport.finish_render(transport.context);
    if (operation_error) |err| return err;
}

fn emitManage(
    transport: Transport,
    operation: types.ManageOperation,
) anyerror!void {
    const resolver: ?*const Resolver = if (transport.resolver) |*value| value else null;
    return transport.emit_manage(transport.context, resolver, operation);
}

fn emitRender(
    transport: Transport,
    operation: types.RenderOperation,
) anyerror!void {
    const resolver: ?*const Resolver = if (transport.resolver) |*value| value else null;
    return transport.emit_render(transport.context, resolver, operation);
}

fn finishManageProxy(context: *anyopaque) anyerror!void {
    const manager: *live.Manager = @ptrCast(@alignCast(context));
    return manager.manageFinish();
}

fn finishRenderProxy(context: *anyopaque) anyerror!void {
    const manager: *live.Manager = @ptrCast(@alignCast(context));
    return manager.renderFinish();
}

fn emitManageProxy(
    _: *anyopaque,
    resolver: ?*const Resolver,
    operation: types.ManageOperation,
) anyerror!void {
    switch (operation) {
        .close => |id| (try resolveWindow(resolver, id)).close(),
        .propose_dimensions => |value| (try resolveWindow(resolver, value.window)).proposeDimensions(value.size.width, value.size.height),
        .use_csd => |id| (try resolveWindow(resolver, id)).useCsd(),
        .use_ssd => |id| (try resolveWindow(resolver, id)).useSsd(),
        .set_dimension_bounds => |value| (try resolveWindow(resolver, value.window)).setDimensionBounds(value.max.width, value.max.height),
        .fullscreen => |value| (try resolveWindow(resolver, value.window)).fullscreen(try resolveOutput(resolver, value.output)),
        .exit_fullscreen => |id| (try resolveWindow(resolver, id)).exitFullscreen(),
        .focus_window => |value| (try resolveSeat(resolver, value.seat)).focusWindow(try resolveWindow(resolver, value.window)),
        .focus_shell_surface => |value| (try resolveSeat(resolver, value.seat)).focusShellSurface(try resolveShellSurface(resolver, value.shell_surface)),
        .clear_focus => |id| (try resolveSeat(resolver, id)).clearFocus(),
        .op_start_pointer => |id| (try resolveSeat(resolver, id)).opStartPointer(),
        .op_end => |id| (try resolveSeat(resolver, id)).opEnd(),
        .pointer_warp => |value| (try resolveSeat(resolver, value.seat)).pointerWarp(value.position.x, value.position.y),
        .pointer_binding_enable => |id| (try resolvePointerBinding(resolver, id)).enable(),
        .pointer_binding_disable => |id| (try resolvePointerBinding(resolver, id)).disable(),
        .set_tiled => |value| {
            const window = try resolveWindow(resolver, value.window);
            const edges: wayland.client.river.WindowV1.Edges = @bitCast(value.edges);
            window.setTiled(edges);
        },
    }
}

fn emitRenderProxy(
    _: *anyopaque,
    resolver: ?*const Resolver,
    operation: types.RenderOperation,
) anyerror!void {
    switch (operation) {
        .hide => |id| (try resolveWindow(resolver, id)).hide(),
        .show => |id| (try resolveWindow(resolver, id)).show(),
        .set_borders => |value| {
            const window = try resolveWindow(resolver, value.window);
            const edges: wayland.client.river.WindowV1.Edges = @bitCast(value.edges);
            window.setBorders(edges, value.width, value.rgba[0], value.rgba[1], value.rgba[2], value.rgba[3]);
        },
        .set_clip_box => |value| {
            const window = try resolveWindow(resolver, value.window);
            window.setClipBox(value.box.x, value.box.y, value.box.width, value.box.height);
        },
        .set_content_clip_box => |value| {
            const window = try resolveWindow(resolver, value.window);
            window.setContentClipBox(value.box.x, value.box.y, value.box.width, value.box.height);
        },
        .set_position => |value| (try resolveNode(resolver, value.node)).setPosition(value.position.x, value.position.y),
        .place_top => |id| (try resolveNode(resolver, id)).placeTop(),
        .place_bottom => |id| (try resolveNode(resolver, id)).placeBottom(),
        .place_above => |value| (try resolveNode(resolver, value.node)).placeAbove(try resolveNode(resolver, value.other)),
        .place_below => |value| (try resolveNode(resolver, value.node)).placeBelow(try resolveNode(resolver, value.other)),
        .decoration_set_offset => |value| (try resolveDecoration(resolver, value.decoration)).setOffset(value.offset.x, value.offset.y),
        .decoration_sync_next_commit => |id| (try resolveDecoration(resolver, id)).syncNextCommit(),
        .shell_surface_sync_next_commit => |id| (try resolveShellSurface(resolver, id)).syncNextCommit(),
    }
}

fn resolveWindow(resolver: ?*const Resolver, id: types.WindowId) anyerror!*wayland.client.river.WindowV1 {
    const value = resolver orelse return error.MissingResolver;
    return value.window(value.context, id);
}

fn resolveNode(resolver: ?*const Resolver, id: types.NodeId) anyerror!*wayland.client.river.NodeV1 {
    const value = resolver orelse return error.MissingResolver;
    return value.node(value.context, id);
}

fn resolveSeat(resolver: ?*const Resolver, id: types.SeatId) anyerror!*wayland.client.river.SeatV1 {
    const value = resolver orelse return error.MissingResolver;
    return value.seat(value.context, id);
}

fn resolveOutput(resolver: ?*const Resolver, id: types.OutputId) anyerror!*wayland.client.river.OutputV1 {
    const value = resolver orelse return error.MissingResolver;
    return value.output(value.context, id);
}

fn resolveShellSurface(resolver: ?*const Resolver, id: types.ShellSurfaceId) anyerror!*wayland.client.river.ShellSurfaceV1 {
    const value = resolver orelse return error.MissingResolver;
    return value.shell_surface(value.context, id);
}

fn resolveDecoration(resolver: ?*const Resolver, id: types.DecorationId) anyerror!*wayland.client.river.DecorationV1 {
    const value = resolver orelse return error.MissingResolver;
    return value.decoration(value.context, id);
}

fn resolvePointerBinding(resolver: ?*const Resolver, id: types.PointerBindingId) anyerror!*wayland.client.river.PointerBindingV1 {
    const value = resolver orelse return error.MissingResolver;
    const callback = value.pointer_binding orelse return error.MissingPointerBindingResolver;
    return callback(value.context, id);
}

/// A compositor-free request trace.  It records host operations without
/// importing a generated proxy into the test fixture or manufacturing an
/// invalid opaque Wayland pointer.
pub const TraceEvent = union(enum) {
    manage: types.ManageOperation,
    render: types.RenderOperation,
    manage_finish,
    render_finish,
};

pub const Trace = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(TraceEvent) = .empty,
    fail_after: ?usize = null,
    emitted: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Trace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Trace) void {
        self.events.deinit(self.allocator);
    }

    pub fn items(self: *const Trace) []const TraceEvent {
        return self.events.items;
    }

    pub fn failAfter(self: *Trace, emission: usize) void {
        self.fail_after = emission;
    }
};

pub fn traceManage(trace: *Trace, plan: types.ManagePlan) anyerror!void {
    return applyManageTransport(traceTransport(trace, .managing), plan);
}

pub fn traceRender(trace: *Trace, plan: types.RenderPlan) anyerror!void {
    return applyRenderTransport(traceTransport(trace, .rendering), plan);
}

fn traceTransport(trace: *Trace, phase: SequencePhase) Transport {
    return .{
        .phase = phase,
        .context = @ptrCast(trace),
        .resolver = null,
        .emit_manage = traceEmitManage,
        .emit_render = traceEmitRender,
        .finish_manage = traceFinishManage,
        .finish_render = traceFinishRender,
    };
}

fn traceEmitManage(
    context: *anyopaque,
    _: ?*const Resolver,
    operation: types.ManageOperation,
) anyerror!void {
    const trace: *Trace = @ptrCast(@alignCast(context));
    try traceBeforeEmit(trace);
    try trace.events.append(trace.allocator, .{ .manage = operation });
}

fn traceEmitRender(
    context: *anyopaque,
    _: ?*const Resolver,
    operation: types.RenderOperation,
) anyerror!void {
    const trace: *Trace = @ptrCast(@alignCast(context));
    try traceBeforeEmit(trace);
    try trace.events.append(trace.allocator, .{ .render = operation });
}

fn traceBeforeEmit(trace: *Trace) !void {
    if (trace.fail_after) |limit| {
        if (trace.emitted == limit) return error.InjectedTraceFailure;
    }
    trace.emitted += 1;
}

fn traceFinishManage(context: *anyopaque) anyerror!void {
    const trace: *Trace = @ptrCast(@alignCast(context));
    try trace.events.append(trace.allocator, .manage_finish);
}

fn traceFinishRender(context: *anyopaque) anyerror!void {
    const trace: *Trace = @ptrCast(@alignCast(context));
    try trace.events.append(trace.allocator, .render_finish);
}

test "manage trace preserves typed operations and always finishes after failure" {
    const window = types.WindowId.init(1);
    const output = types.OutputId.init(2);
    const plan = types.ManagePlan{ .operations = &.{
        .{ .close = window },
        .{ .fullscreen = .{ .window = window, .output = output } },
        .{ .set_tiled = .{ .window = window, .edges = 0x5 } },
    } };

    var trace = Trace.init(std.testing.allocator);
    defer trace.deinit();
    trace.failAfter(1);

    try std.testing.expectError(error.InjectedTraceFailure, traceManage(&trace, plan));
    try std.testing.expectEqual(@as(usize, 2), trace.items().len);
    try std.testing.expectEqualDeep(TraceEvent{ .manage = .{ .close = window } }, trace.items()[0]);
    try std.testing.expectEqual(TraceEvent.manage_finish, trace.items()[1]);
}

test "render trace emits every render operation before render finish" {
    const window = types.WindowId.init(1);
    const node = types.NodeId.init(2);
    const decoration = types.DecorationId.init(3);
    const shell_surface = types.ShellSurfaceId.init(4);
    const plan = types.RenderPlan{ .operations = &.{
        .{ .hide = window },
        .{ .show = window },
        .{ .set_borders = .{ .window = window, .edges = 0xf, .width = 2, .rgba = .{ 1, 2, 3, 4 } } },
        .{ .set_clip_box = .{ .window = window, .box = .{ .x = 1, .y = 2, .width = 3, .height = 4 } } },
        .{ .set_content_clip_box = .{ .window = window, .box = .{ .x = 5, .y = 6, .width = 7, .height = 8 } } },
        .{ .set_position = .{ .node = node, .position = .{ .x = -2, .y = 9 } } },
        .{ .place_top = node },
        .{ .place_bottom = node },
        .{ .place_above = .{ .node = node, .other = types.NodeId.init(5) } },
        .{ .place_below = .{ .node = node, .other = types.NodeId.init(6) } },
        .{ .decoration_set_offset = .{ .decoration = decoration, .offset = .{ .x = 10, .y = 11 } } },
        .{ .decoration_sync_next_commit = decoration },
        .{ .shell_surface_sync_next_commit = shell_surface },
    } };

    var trace = Trace.init(std.testing.allocator);
    defer trace.deinit();
    try traceRender(&trace, plan);
    try std.testing.expectEqual(@as(usize, plan.operations.len + 1), trace.items().len);
    try std.testing.expectEqual(TraceEvent.render_finish, trace.items()[trace.items().len - 1]);
    for (plan.operations, 0..) |operation, index| {
        try std.testing.expectEqualDeep(TraceEvent{ .render = operation }, trace.items()[index]);
    }
}

test "transport rejects the wrong phase without sending a finish request" {
    var trace = Trace.init(std.testing.allocator);
    defer trace.deinit();
    const manage = types.ManagePlan{ .operations = &.{} };
    const render = types.RenderPlan{ .operations = &.{} };

    try std.testing.expectError(
        error.InvalidSequencePhase,
        applyManageTransport(traceTransport(&trace, .rendering), manage),
    );
    try std.testing.expectError(
        error.InvalidSequencePhase,
        applyRenderTransport(traceTransport(&trace, .managing), render),
    );
    try std.testing.expectEqual(@as(usize, 0), trace.items().len);
}

test "generated emitter requires an injected resolver" {
    const operation: types.ManageOperation = .{ .close = types.WindowId.init(1) };
    try std.testing.expectError(error.MissingResolver, emitManageProxy(undefined, null, operation));
}
