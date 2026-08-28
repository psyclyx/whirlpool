//! Wayland platform boundary.
//!
//! Transport and polling live here. Protocol-specific owners layer on this
//! boundary without leaking generated proxy lifetimes into WM policy.

pub const client = @import("client.zig");
pub const event_loop = @import("event_loop.zig");
pub const layer_shell = @import("layer_shell.zig");
pub const runtime = @import("runtime.zig");
