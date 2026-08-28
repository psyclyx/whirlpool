//! Synchronized surface preparation and render emission.

const std = @import("std");
const host = @import("whirlpool-host");
const plans = @import("whirlpool-river-live-plans");
const resolver = @import("resolver.zig");

const coordinator = host.river_coordinator;
const types = host.types;

/// Build render callbacks around runtime's surface queue and live objects.
pub fn emitter(comptime Runtime: type, runtime: *Runtime) coordinator.Emitter {
    return .{
        .context = runtime,
        .prepare_surface = prepareCallback(Runtime),
        .sync_surface = syncCallback(Runtime),
        .commit_surface = commitCallback(Runtime),
        .render_operation = renderCallback(Runtime),
        .finish_render = finishCallback(Runtime),
    };
}

fn runtimeFrom(comptime Runtime: type, raw: ?*anyopaque) *Runtime {
    return @ptrCast(@alignCast(raw orelse unreachable));
}

fn prepareCallback(comptime Runtime: type) *const fn (?*anyopaque, coordinator.SubmittedCommit) anyerror!void {
    return struct {
        fn call(raw: ?*anyopaque, commit: coordinator.SubmittedCommit) anyerror!void {
            const runtime = runtimeFrom(Runtime, raw);
            // All roles must resolve before the first infallible sync request.
            if (runtime.driver == null) switch (commit.role) {
                .shell => |id| _ = try runtime.adapter.objects.shellSurfaceProxy(id),
                .decoration => |id| _ = try runtime.adapter.objects.decorationProxy(id),
            };
            const hooks = runtime.options.surfaces orelse return error.MissingSurfacePresenter;
            return hooks.prepare(hooks.context, commit);
        }
    }.call;
}

fn syncCallback(comptime Runtime: type) *const fn (?*anyopaque, coordinator.SurfaceRole) void {
    return struct {
        fn call(raw: ?*anyopaque, role: coordinator.SurfaceRole) void {
            const runtime = runtimeFrom(Runtime, raw);
            if (runtime.driver) |injected| return injected.sync_surface(injected.context, role);
            switch (role) {
                .shell => |id| (runtime.adapter.objects.shellSurfaceProxy(id) catch unreachable).syncNextCommit(),
                .decoration => |id| (runtime.adapter.objects.decorationProxy(id) catch unreachable).syncNextCommit(),
            }
        }
    }.call;
}

fn commitCallback(comptime Runtime: type) *const fn (?*anyopaque, coordinator.SubmittedCommit) void {
    return struct {
        fn call(raw: ?*anyopaque, commit: coordinator.SubmittedCommit) void {
            const runtime = runtimeFrom(Runtime, raw);
            const hooks = runtime.options.surfaces.?;
            hooks.commit(hooks.context, commit);
            std.debug.assert(runtime.surface_queue.complete(commit));
            runtime.stats.committed_surfaces += 1;
        }
    }.call;
}

fn renderCallback(comptime Runtime: type) *const fn (?*anyopaque, types.RenderOperation) anyerror!void {
    return struct {
        fn call(raw: ?*anyopaque, operation: types.RenderOperation) anyerror!void {
            const runtime = runtimeFrom(Runtime, raw);
            if (runtime.driver) |injected| return injected.emit_render(injected.context, operation);
            var live = plans.liveTransport(runtime.manager.?, resolver.init(Runtime, runtime), .rendering);
            return live.emit_render(live.context, &live.resolver.?, operation);
        }
    }.call;
}

fn finishCallback(comptime Runtime: type) *const fn (?*anyopaque) anyerror!void {
    return struct {
        fn call(raw: ?*anyopaque) anyerror!void {
            const runtime = runtimeFrom(Runtime, raw);
            if (runtime.driver) |injected| return injected.finish_render(injected.context);
            return runtime.manager.?.renderFinish();
        }
    }.call;
}
