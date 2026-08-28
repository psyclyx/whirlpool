//! Platform-neutral River host contracts and deterministic host composition.
//!
//! Concrete Wayland code owns proxy pointers and request transport. This module
//! owns River object identities, staged facts, sequence legality, request
//! plans, and the one explicit WM-plan translation seam. It does not import
//! UI or graphics APIs.

pub const types = @import("types.zig");
pub const proxy_maps = @import("proxy/maps.zig");
pub const staged_facts = @import("staged/facts.zig");
pub const phase = @import("phase.zig");
pub const wm_bridge = @import("wm/bridge.zig");
pub const composition = @import("composition.zig");
pub const decoration_selection = @import("decoration/selection.zig");
pub const skia_scene = @import("skia/scene.zig");
pub const lua_composition = @import("lua/composition.zig");
pub const surface_composition = @import("surface/composition.zig");
pub const river_coordinator = @import("river/coordinator.zig");

test {
    _ = types;
    _ = proxy_maps;
    _ = staged_facts;
    _ = phase;
    _ = wm_bridge;
    _ = composition;
    _ = decoration_selection;
    _ = skia_scene;
    _ = lua_composition;
    _ = surface_composition;
    _ = river_coordinator;
}
