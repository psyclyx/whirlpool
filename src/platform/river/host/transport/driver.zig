//! Adapter from an injected host driver to the River plan transport.

const std = @import("std");
const host = @import("whirlpool-host");
const plans = @import("whirlpool-river-live-plans");

const types = host.types;

/// Build a manage transport around runtime's injected driver.
pub fn manage(comptime Runtime: type, runtime: *Runtime) plans.Transport {
    std.debug.assert(runtime.driver != null);
    return .{
        .phase = .managing,
        .context = runtime,
        .resolver = null,
        .emit_manage = emitManageCallback(Runtime),
        .emit_render = emitRenderUnused,
        .finish_manage = finishManageCallback(Runtime),
        .finish_render = finishRenderCallback(Runtime),
    };
}

fn runtimeFrom(comptime Runtime: type, raw: *anyopaque) *Runtime {
    return @ptrCast(@alignCast(raw));
}

fn emitManageCallback(comptime Runtime: type) *const fn (*anyopaque, ?*const plans.Resolver, types.ManageOperation) anyerror!void {
    return struct {
        fn call(raw: *anyopaque, _: ?*const plans.Resolver, operation: types.ManageOperation) anyerror!void {
            const driver = runtimeFrom(Runtime, raw).driver.?;
            return driver.emit_manage(driver.context, operation);
        }
    }.call;
}

fn emitRenderUnused(_: *anyopaque, _: ?*const plans.Resolver, _: types.RenderOperation) anyerror!void {
    return error.InvalidSequencePhase;
}

fn finishManageCallback(comptime Runtime: type) *const fn (*anyopaque) anyerror!void {
    return struct {
        fn call(raw: *anyopaque) anyerror!void {
            const driver = runtimeFrom(Runtime, raw).driver.?;
            return driver.finish_manage(driver.context);
        }
    }.call;
}

fn finishRenderCallback(comptime Runtime: type) *const fn (*anyopaque) anyerror!void {
    return struct {
        fn call(raw: *anyopaque) anyerror!void {
            const driver = runtimeFrom(Runtime, raw).driver.?;
            return driver.finish_render(driver.context);
        }
    }.call;
}
