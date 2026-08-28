//! Pure Whirlpool window-management kernel.
//!
//! This module owns policy state, structural identity, semantic commands, and
//! generic layout plan values. It intentionally imports only the Zig
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
pub const ColumnId = ids.ColumnId;
pub const NodeId = ids.NodeId;

pub const Axis = types.Axis;
pub const ContainerMode = types.ContainerMode;
pub const Direction = types.Direction;
pub const Lifecycle = types.Lifecycle;
pub const Placement = types.Placement;
pub const Point = types.Point;
pub const Size = types.Size;
pub const Rect = types.Rect;
pub const Camera = types.Camera;
pub const Child = types.Child;
pub const Node = types.Node;
pub const Column = types.Column;
pub const Tag = types.Tag;
pub const Output = types.Output;
pub const Window = types.Window;
pub const WindowSpec = types.WindowSpec;
pub const OutputSpec = types.OutputSpec;
pub const ColumnSpec = types.ColumnSpec;

pub const Command = command.Command;
pub const ColumnWidthStep = command.ColumnWidthStep;
pub const Batch = command.Batch;
pub const ApplyResult = world.ApplyResult;
pub const World = world.World;
pub const WorldView = world.WorldView;
pub const WorldCheckpoint = world.WorldCheckpoint;

pub const FRect = layout.FRect;
pub const PlanContext = layout.PlanContext;
pub const CameraTarget = layout.CameraTarget;
pub const DimensionProposal = layout.DimensionProposal;
pub const RenderEntry = layout.RenderEntry;
pub const ManagePlan = layout.ManagePlan;
pub const RenderPlan = layout.RenderPlan;
pub const LayoutPlans = layout.Plans;

pub const Action = input.Action;
pub const ActionPlan = input.ActionPlan;
pub const MissingExecution = input.MissingExecution;
pub const MissingExecutionReason = input.MissingExecutionReason;
pub const MoveAction = input.MoveAction;
pub const PointerGesture = input.PointerGesture;
pub const PointerGestureKind = input.PointerGestureKind;
pub const ResizeAction = input.ResizeAction;
pub const planAction = input.planAction;

test {
    _ = @import("world_test.zig");
    _ = @import("ids.zig");
    _ = @import("types.zig");
    _ = @import("command.zig");
    _ = @import("world.zig");
    _ = @import("layout.zig");
    _ = @import("lifecycle.zig");
    _ = @import("input.zig");
}
