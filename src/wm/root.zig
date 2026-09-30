//! Pure Whirlpool window-management kernel.
//!
//! This module owns compositor resource facts, atomic resource effects, and
//! generic presentation plan values. It intentionally imports only the Zig
//! standard library through its implementation files: no Wayland, River,
//! Lua, Vulkan, Skia, graphics, or host code crosses this boundary.

pub const ids = @import("ids.zig");
pub const types = @import("types.zig");
pub const command = @import("command.zig");
pub const world = @import("world.zig");
pub const layout = @import("layout.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const input = @import("input.zig");

pub const Id = ids.Id;
pub const WindowId = ids.WindowId;
pub const OutputId = ids.OutputId;
pub const TagId = ids.TagId;
pub const Lifecycle = types.Lifecycle;
pub const Placement = types.Placement;
pub const PlacementTransition = types.PlacementTransition;
pub const Point = types.Point;
pub const Size = types.Size;
pub const SizeHints = types.SizeHints;
pub const Rect = types.Rect;
pub const ResizeEdges = types.ResizeEdges;
pub const Tag = types.Tag;
pub const Output = types.Output;
pub const Window = types.Window;
pub const Identifier = types.Identifier;
pub const WindowSpec = types.WindowSpec;
pub const OutputSpec = types.OutputSpec;
pub const Command = command.Command;
pub const Batch = command.Batch;
pub const ApplyResult = world.ApplyResult;
pub const World = world.World;
pub const WorldView = world.WorldView;
pub const WorldCheckpoint = world.WorldCheckpoint;

pub const PlanContext = layout.PlanContext;
pub const DimensionProposal = layout.DimensionProposal;
pub const RenderEntry = layout.RenderEntry;
pub const ManagePlan = layout.ManagePlan;
pub const RenderPlan = layout.RenderPlan;
pub const LayoutPlans = layout.Plans;

pub const PointerGesture = input.PointerGesture;
pub const PointerGestureKind = input.PointerGestureKind;

test {
    _ = @import("world/test.zig");
    _ = @import("ids.zig");
    _ = @import("types.zig");
    _ = @import("command.zig");
    _ = @import("world.zig");
    _ = @import("layout.zig");
    _ = @import("lifecycle.zig");
    _ = @import("input.zig");
}
