//! Generic, protocol-free layout plan values.
//!
//! Layout policy lives outside the WM kernel. These values are the bounded
//! snapshot-to-plan result consumed by host and River adapters.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const FRect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const CameraTarget = struct {
    tag: ids.TagId,
    current: f32,
    target: f32,
    strip_width: f32,
};
pub const DimensionProposal = struct {
    window: ids.WindowId,
    column: ids.ColumnId,
    size: types.Size,
    virtual: FRect,
};
pub const RenderEntry = struct {
    window: ids.WindowId,
    column: ids.ColumnId,
    placement: types.Placement,
    target_virtual: FRect,
    screen: types.Rect,
    clip: types.Rect,
    visible: bool,
};
pub const PlanContext = struct {
    allocator: std.mem.Allocator,
    epoch: u64,
    output: ids.OutputId,
    camera: CameraTarget,
};

pub const ManagePlan = struct {
    context: PlanContext,
    dimensions: std.ArrayList(DimensionProposal) = .empty,

    pub fn deinit(self: *ManagePlan) void {
        self.dimensions.deinit(self.context.allocator);
    }

    pub fn dimensionSlice(self: *const ManagePlan) []const DimensionProposal {
        return self.dimensions.items;
    }
};

pub const RenderPlan = struct {
    context: PlanContext,
    entries: std.ArrayList(RenderEntry) = .empty,

    pub fn deinit(self: *RenderPlan) void {
        self.entries.deinit(self.context.allocator);
    }

    pub fn entrySlice(self: *const RenderPlan) []const RenderEntry {
        return self.entries.items;
    }
};

pub const Plans = struct {
    manage: ManagePlan,
    render: RenderPlan,

    pub fn deinit(self: *Plans) void {
        self.render.deinit();
        self.manage.deinit();
        self.* = undefined;
    }
};
