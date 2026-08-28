//! Host-independent retained UI primitives.
//!
//! The UI core owns a retained node tree and the mutation protocol used to
//! update it.  It deliberately stops at a small scene description boundary:
//! platform surfaces, graphics devices, text shaping, and script runtimes are
//! all consumers of this module, never dependencies of it.

pub const tree = @import("tree.zig");
pub const properties = @import("properties.zig");
pub const scene = @import("scene.zig");
pub const signal = @import("signal.zig");
pub const animation = @import("animation.zig");
pub const target = @import("target.zig");

pub const NodeHandle = tree.NodeHandle;
pub const NodeKind = tree.NodeKind;
pub const Edges = tree.Edges;
pub const Color = tree.Color;
pub const DirtyFlags = tree.DirtyFlags;
pub const NodeProperties = tree.NodeProperties;
pub const NodeSnapshot = tree.NodeSnapshot;
pub const PropertyValue = tree.PropertyValue;
pub const NodeError = tree.NodeError;
pub const Scene = tree.Scene;
pub const MountContext = tree.MountContext;
pub const SceneDelta = scene.SceneDelta;
pub const Signal = signal.Signal;
pub const SignalError = signal.SignalError;
pub const AnimationTarget = animation.Target;
pub const SurfaceDescription = target.SurfaceDescription;
pub const Frame = target.Frame;
pub const RecordingTarget = target.RecordingTarget;

test {
    _ = tree;
    _ = properties;
    _ = scene;
    _ = signal;
    _ = animation;
    _ = target;
}
