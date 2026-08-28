//! Platform-neutral River v5 boundary vocabulary.
//!
//! These IDs identify River protocol objects inside the host. They are not WM
//! model IDs and deliberately carry no Wayland proxy or unfinished WM type.

const std = @import("std");

fn Id(comptime label: []const u8) type {
    return struct {
        const Self = @This();

        value: u64,

        pub fn init(value: u64) Self {
            std.debug.assert(value != 0);
            return .{ .value = value };
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{s}({d})", .{ label, self.value });
        }
    };
}

pub const WindowId = Id("window");
pub const OutputId = Id("output");
pub const SeatId = Id("seat");
pub const NodeId = Id("node");
pub const ShellSurfaceId = Id("shell_surface");
pub const DecorationId = Id("decoration");
pub const PointerBindingId = Id("pointer_binding");

/// Opaque identity supplied by a concrete Wayland bridge. The host never
/// dereferences it, which keeps proxy ownership in the platform layer.
pub const ProxyRef = struct {
    value: usize,

    pub fn init(value: usize) !ProxyRef {
        if (value == 0) return error.NullProxy;
        return .{ .value = value };
    }
};

pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { width: i32, height: i32 };
pub const Box = struct { x: i32, y: i32, width: i32, height: i32 };

pub const DimensionsHint = struct {
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
};

pub const WindowSize = struct { window: WindowId, size: Size };
pub const WindowOutput = struct { window: WindowId, output: OutputId };
pub const WindowBounds = struct { window: WindowId, max: Size };
pub const SeatWindow = struct { seat: SeatId, window: WindowId };
pub const SeatShellSurface = struct { seat: SeatId, shell_surface: ShellSurfaceId };
pub const SeatPoint = struct { seat: SeatId, position: Point };
pub const WindowEdges = struct { window: WindowId, edges: u32 };
pub const WindowBox = struct { window: WindowId, box: Box };
pub const NodePoint = struct { node: NodeId, position: Point };
pub const NodeOrder = struct { node: NodeId, other: NodeId };
pub const DecorationOffset = struct { decoration: DecorationId, offset: Point };
pub const WindowBorders = struct {
    window: WindowId,
    edges: u32,
    width: i32,
    rgba: [4]u32,
};

pub const DecorationHint = enum(u32) {
    none = 0,
    client = 1,
    server = 2,
    _,
};

pub const PresentationMode = enum(u32) {
    none = 0,
    fullscreen = 1,
    _,
};

/// State changes accumulated until River terminates the sequence with a
/// manage_start event.  Protocol notifications that do not affect the WM
/// world are handled at the callback boundary instead of being staged.
pub const ManageFact = union(enum) {
    window_closed: WindowId,
    window_maximize_requested: WindowId,
    window_unmaximize_requested: WindowId,
    window_fullscreen_requested: struct { window: WindowId, output: ?OutputId },
    window_exit_fullscreen_requested: WindowId,
    window_minimize_requested: WindowId,

    output_removed: OutputId,
    output_position: struct { output: OutputId, position: Point },
    output_dimensions: struct { output: OutputId, size: Size },

    seat_removed: SeatId,
    seat_window_interaction: struct { seat: SeatId, window: WindowId },
};

/// river_window_v1.dimensions is the only v5 event staged for render_start.
pub const RenderFact = union(enum) {
    window_dimensions: struct { window: WindowId, size: Size },
};

pub const ManageOperation = union(enum) {
    close: WindowId,
    propose_dimensions: WindowSize,
    use_csd: WindowId,
    use_ssd: WindowId,
    set_dimension_bounds: WindowBounds,
    fullscreen: WindowOutput,
    exit_fullscreen: WindowId,
    focus_window: SeatWindow,
    focus_shell_surface: SeatShellSurface,
    clear_focus: SeatId,
    op_start_pointer: SeatId,
    op_end: SeatId,
    pointer_warp: SeatPoint,
    pointer_binding_enable: PointerBindingId,
    pointer_binding_disable: PointerBindingId,
    set_tiled: WindowEdges,
};

pub const RenderOperation = union(enum) {
    hide: WindowId,
    show: WindowId,
    set_borders: WindowBorders,
    set_clip_box: WindowBox,
    set_content_clip_box: WindowBox,
    set_position: NodePoint,
    place_top: NodeId,
    place_bottom: NodeId,
    place_above: NodeOrder,
    place_below: NodeOrder,
    decoration_set_offset: DecorationOffset,
    decoration_sync_next_commit: DecorationId,
    shell_surface_sync_next_commit: ShellSurfaceId,
};

pub const ManagePlan = struct {
    operations: []const ManageOperation,
};

pub const RenderPlan = struct {
    operations: []const RenderOperation,
};
