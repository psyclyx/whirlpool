//! Generic, protocol-free window configuration and presentation plans.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const DimensionProposal = struct {
    window: ids.WindowId,
    size: ?types.Size,
    placement: types.Placement = .unplaced,
};
pub const Border = struct {
    edges: u32 = 0,
    width: i32 = 0,
    rgba: [4]u32 = .{ 0, 0, 0, 0 },
};
pub const RenderEntry = struct {
    window: ids.WindowId,
    screen: types.Rect,
    clip: types.Rect,
    /// Optional whole-window clip relative to the content origin.
    window_clip: ?types.Rect = null,
    visible: bool,
    border: ?Border = null,
    decoration_height: i32 = 0,
    /// Provider-defined stacking order; larger values are presented above lower values.
    z_index: i32 = 0,
};
pub const PlanContext = struct { allocator: std.mem.Allocator, epoch: u64, output: ids.OutputId };
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
    needs_frame: bool = false,

    pub fn deinit(self: *Plans) void {
        self.render.deinit();
        self.manage.deinit();
        self.* = undefined;
    }
};
