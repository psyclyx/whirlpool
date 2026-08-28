//! Composition of River manage and render transport edges.

const coordinator = @import("whirlpool-host").river_coordinator;
const plans = @import("whirlpool-river-live-plans");
const driver = @import("driver.zig");
const resolver = @import("resolver.zig");
const surface = @import("surface.zig");

/// Build the live or injected manage transport selected by runtime.
pub fn manage(comptime Runtime: type, runtime: *Runtime) plans.Transport {
    if (runtime.driver != null) return driver.manage(Runtime, runtime);
    return plans.liveTransport(runtime.manager orelse unreachable, resolver.init(Runtime, runtime), .managing);
}

/// Build the synchronized render emitter selected by runtime.
pub fn renderEmitter(comptime Runtime: type, runtime: *Runtime) coordinator.Emitter {
    return surface.emitter(Runtime, runtime);
}

/// Finish an empty manage transaction before returning source.
pub fn finishManageError(comptime Runtime: type, runtime: *Runtime, source: anyerror) anyerror {
    plans.applyManageTransport(manage(Runtime, runtime), .{ .operations = &.{} }) catch |finish_err| return finish_err;
    return source;
}

/// Finish an empty render transaction before returning source.
pub fn finishRenderError(comptime Runtime: type, runtime: *Runtime, source: anyerror) anyerror {
    coordinator.runRender(.{ .operations = &.{} }, &.{}, renderEmitter(Runtime, runtime)) catch |finish_err| return finish_err;
    return source;
}
