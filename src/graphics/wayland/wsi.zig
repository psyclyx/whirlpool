//! Vulkan Wayland WSI ownership boundary.
//!
//! Context owns display-wide device state. Swapchain owns resources for one
//! wl_surface. The shared Vulkan ABI remains private to this package.

const std = @import("std");

pub const Context = @import("wsi/context.zig").Context;
pub const Swapchain = @import("wsi/swapchain.zig").Swapchain;

test "WSI separates shared device context from per-surface swapchain" {
    try std.testing.expect(@sizeOf(Context) < @sizeOf(Swapchain));
}
