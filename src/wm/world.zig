//! Authoritative WM policy state and its structural transaction boundary.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");
const command = @import("command.zig");
const snapshot_mod = @import("world/snapshot.zig");
const world_policy = @import("world/policy.zig");
const world_tree = @import("world/tree.zig");
const validation = @import("world/validation.zig");

pub const WindowId = ids.WindowId;
pub const OutputId = ids.OutputId;
pub const TagId = ids.TagId;
pub const ColumnId = ids.ColumnId;
pub const NodeId = ids.NodeId;
pub const Window = types.Window;
pub const Output = types.Output;
pub const Tag = types.Tag;
pub const Column = types.Column;
pub const Node = types.Node;
pub const Child = types.Child;
pub const Mark = types.Mark;
pub const WindowSpec = types.WindowSpec;
pub const OutputSpec = types.OutputSpec;
pub const OutputConfig = types.OutputConfig;
pub const OutputTransform = types.OutputTransform;
pub const ColumnSpec = types.ColumnSpec;
pub const Rect = types.Rect;
pub const ResizeEdges = types.ResizeEdges;
pub const Point = types.Point;
pub const Axis = types.Axis;
pub const ContainerMode = types.ContainerMode;
pub const Direction = types.Direction;
pub const Lifecycle = types.Lifecycle;
pub const Placement = types.Placement;
pub const PlacementTransition = types.PlacementTransition;
pub const Command = command.Command;
pub const ColumnWidthStep = command.ColumnWidthStep;

const WindowStore = ids.Store(Window, .window);
const OutputStore = ids.Store(Output, .output);
const TagStore = ids.Store(Tag, .tag);
const ColumnStore = ids.Store(Column, .column);
const NodeStore = ids.Store(Node, .node);

pub const ApplyResult = struct {
    epoch: u64,
    changed: bool,
};

/// An owned, protocol-free checkpoint of all WM policy state. It is the
/// persistence boundary for this module; serialization and rebinding a new
/// compositor's identities belong to the host/configuration layer.
pub const PersistenceState = struct {
    world: World,

    pub fn deinit(self: *PersistenceState) void {
        self.world.deinit();
        self.* = undefined;
    }
};

/// A world owns every policy object. The stores are deliberately private:
/// callers can observe immutable records, but can only create or mutate them
/// through operations that preserve the indices and reciprocal links.
pub const World = struct {
    allocator: std.mem.Allocator,
    epoch_value: u64 = 0,
    next_focus_serial: u64 = 1,
    windows: WindowStore,
    outputs: OutputStore,
    tags: TagStore,
    columns: ColumnStore,
    nodes: NodeStore,
    window_index: std.AutoHashMap(WindowId, NodeId),

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .windows = WindowStore.init(allocator),
            .outputs = OutputStore.init(allocator),
            .tags = TagStore.init(allocator),
            .columns = ColumnStore.init(allocator),
            .nodes = NodeStore.init(allocator),
            .window_index = std.AutoHashMap(WindowId, NodeId).init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        self.window_index.deinit();
        self.nodes.deinit();
        self.columns.deinit();
        self.tags.deinit();
        self.outputs.deinit();
        self.windows.deinit();
    }

    pub fn epoch(self: *const World) u64 {
        return self.epoch_value;
    }

    pub fn createTag(self: *World) !TagId {
        const id = try self.tags.insert(.{ .id = undefined });
        self.advanceEpoch();
        return id;
    }

    pub fn createNamedTag(self: *World, name: []const u8) !TagId {
        try validation.validateName(name);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const id = try self.tags.insert(.{ .id = undefined, .name = owned });
        self.advanceEpoch();
        return id;
    }

    pub fn createOutput(self: *World, spec: OutputSpec) !OutputId {
        try self.requireTag(spec.active_tag);
        try validation.validateRectPair(spec.bounds, spec.usable);
        try validation.validateOutputConfig(spec.configuration);
        const id = try self.outputs.insert(.{
            .id = undefined,
            .active_tag = spec.active_tag,
            .bounds = spec.bounds,
            .usable = spec.usable,
            .configuration = spec.configuration,
        });
        self.advanceEpoch();
        return id;
    }

    pub fn createColumn(self: *World, tag_id: TagId, spec: ColumnSpec) !ColumnId {
        const id = try world_tree.createColumnAt(self, tag_id, world_tree.tagColumnCount(self, tag_id) orelse return error.UnknownTag, spec, false);
        self.advanceEpoch();
        return id;
    }

    pub fn createWindow(self: *World, spec: WindowSpec) !WindowId {
        try self.requireTag(spec.tag);
        try validation.validateFloatingGeometry(spec.floating_geometry);
        if (spec.output) |output_id| try self.requireOutput(output_id);
        const id = try self.windows.insert(.{
            .id = undefined,
            .tag = spec.tag,
            .output = spec.output,
            .lifecycle = .announced,
            .placement = spec.placement,
            .floating_geometry = spec.floating_geometry,
        });
        self.advanceEpoch();
        return id;
    }

    /// Insert an announced window into a column and make it managed. An
    /// omitted column chooses the first column for the window's tag, creating
    /// a default column when the tag is empty.
    pub fn manageWindow(self: *World, window_id: WindowId, maybe_column: ?ColumnId) !void {
        const window = self.windows.getConst(window_id) orelse return error.UnknownWindow;
        if (window.lifecycle != .announced) return error.InvalidLifecycle;
        const column_id = maybe_column orelse blk: {
            if (self.tags.getConst(window.tag)) |tag| {
                if (tag.columns.items.len != 0) break :blk tag.columns.items[0];
            } else return error.UnknownTag;
            break :blk try world_tree.createColumnAt(self, window.tag, 0, .{}, false);
        };
        try world_tree.insertWindowInPlace(self, window_id, column_id);
        self.windows.get(window_id).?.lifecycle = .managed;
        world_tree.repairFocus(self, window.tag);
        self.advanceEpoch();
    }

    fn beginCloseInPlace(self: *World, window_id: WindowId) !void {
        const window = self.windows.get(window_id) orelse return error.UnknownWindow;
        if (window.lifecycle != .managed) return error.InvalidLifecycle;
        window.lifecycle = .closing;
        world_tree.repairFocus(self, window.tag);
    }

    pub fn wrapNode(self: *World, node_id: NodeId, mode: ContainerMode, axis: Axis) !NodeId {
        // The command surface has no result channel. This direct structural
        // helper is useful to hosts that already own the new container id.
        const id = try world_tree.wrapNodeInPlace(self, node_id, mode, axis);
        self.advanceEpoch();
        return id;
    }

    pub fn view(self: *const World) WorldView {
        return WorldView.init(self);
    }

    pub fn checkpoint(self: *const World) !WorldCheckpoint {
        return WorldCheckpoint.init(self);
    }

    pub fn saveState(self: *const World) !PersistenceState {
        return .{ .world = try self.cloneState() };
    }

    pub fn restoreState(self: *World, saved: *const PersistenceState) !void {
        try saved.world.validate();
        var restored = try saved.world.cloneState();
        restored.epoch_value = self.epoch_value +% 1;
        var previous = self.*;
        self.* = restored;
        previous.deinit();
    }

    /// Apply a complete semantic batch atomically. No failed command can
    /// leak an earlier successful command into the live world.
    pub fn applyAtomically(self: *World, commands: command.Batch) !ApplyResult {
        if (commands.len == 0) return .{ .epoch = self.epoch_value, .changed = false };

        var candidate = try self.cloneState();
        errdefer candidate.deinit();
        for (commands) |item| try candidate.applyOne(item);
        try candidate.validate();
        candidate.epoch_value = self.epoch_value +% 1;

        var previous = self.*;
        self.* = candidate;
        previous.deinit();
        return .{ .epoch = self.epoch_value, .changed = true };
    }

    fn advanceEpoch(self: *World) void {
        self.epoch_value +%= 1;
    }

    pub fn validate(self: *const World) !void {
        try validation.validate(self);
    }

    pub fn getOutput(self: *const World, id: OutputId) ?*const Output {
        return self.outputs.getConst(id);
    }

    pub fn getTag(self: *const World, id: TagId) ?*const Tag {
        return self.tags.getConst(id);
    }

    pub fn tagOrdinal(self: *const World, id: TagId) ?usize {
        var ordinal: usize = 0;
        for (self.tags.slots.items) |slot| {
            const tag = slot.value orelse continue;
            if (tag.id == id) return ordinal;
            ordinal += 1;
        }
        return null;
    }

    pub fn tagAt(self: *const World, target: usize) ?TagId {
        var ordinal: usize = 0;
        for (self.tags.slots.items) |slot| {
            const tag = slot.value orelse continue;
            if (ordinal == target) return tag.id;
            ordinal += 1;
        }
        return null;
    }

    pub fn firstOutput(self: *const World) ?OutputId {
        for (self.outputs.slots.items) |slot| if (slot.value) |output| return output.id;
        return null;
    }

    pub fn liveTagCount(self: *const World) usize {
        return self.tags.liveCount();
    }

    pub fn getColumn(self: *const World, id: ColumnId) ?*const Column {
        return self.columns.getConst(id);
    }

    pub fn getNode(self: *const World, id: NodeId) ?*const Node {
        return self.nodes.getConst(id);
    }

    pub fn getWindow(self: *const World, id: WindowId) ?*const Window {
        return self.windows.getConst(id);
    }

    pub fn nodeForWindow(self: *const World, id: WindowId) ?NodeId {
        return self.window_index.get(id);
    }

    pub fn tagColumns(self: *const World, id: TagId) ?[]const ColumnId {
        const value = self.tags.getConst(id) orelse return null;
        return value.columns.items;
    }

    pub fn liveNodeCount(self: *const World) usize {
        return self.nodes.liveCount();
    }

    pub fn liveWindowCount(self: *const World) usize {
        return self.windows.liveCount();
    }

    pub fn liveColumnCount(self: *const World) usize {
        return self.columns.liveCount();
    }

    pub fn cloneState(self: *const World) !World {
        var copy = World.init(self.allocator);
        errdefer copy.deinit();
        copy.epoch_value = self.epoch_value;
        copy.next_focus_serial = self.next_focus_serial;
        copy.windows = try self.windows.clone();
        copy.outputs = try self.outputs.clone();
        copy.tags = try self.tags.clone();
        copy.columns = try self.columns.clone();
        copy.nodes = try self.nodes.clone();

        var iterator = self.window_index.iterator();
        while (iterator.next()) |entry| {
            try copy.window_index.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return copy;
    }

    fn applyOne(self: *World, item: Command) !void {
        switch (item) {
            .focus => |value| try self.applyFocus(value),
            .tree => |value| try self.applyTree(value),
            .geometry => |value| try self.applyGeometry(value),
            .tag => |value| try self.applyTag(value),
            .mark => |value| try self.applyMark(value),
            .transfer => |value| try self.applyTransfer(value),
            .output => |value| try self.applyOutput(value),
            .window => |value| try self.applyWindow(value),
        }
    }

    fn applyFocus(self: *World, item: command.Focus) !void {
        switch (item) {
            .window => |id| try world_tree.focusWindowInPlace(self, id),
            .direction => |value| try world_tree.focusDirectionInPlace(self, value.output, value.direction),
            .mark => |name| try world_policy.focusMarkInPlace(self, name),
        }
    }

    fn applyTree(self: *World, item: command.Tree) !void {
        switch (item) {
            .swap_direction => |value| try world_tree.swapDirectionInPlace(self, value.output, value.direction),
            .insert_window => |value| try world_tree.insertWindowInPlace(self, value.window, value.column),
            .move_node => |value| try world_tree.moveNodeInPlace(self, value.node, value.column),
            .swap_nodes => |value| try world_tree.swapNodesInPlace(self, value.first, value.second),
            .wrap_node => |value| _ = try world_tree.wrapNodeInPlace(self, value.node, value.mode, value.axis),
            .unwrap_node => |id| try world_tree.unwrapNodeInPlace(self, id),
            .set_container_mode => |value| try world_tree.setContainerModeInPlace(self, value.node, value.mode, value.axis),
            .set_active_tab => |value| try world_tree.setActiveTabInPlace(self, value.container, value.child),
            .absorb => |value| try world_tree.absorbInPlace(self, value.output, value.direction),
            .eject => |id| try world_tree.ejectInPlace(self, id),
            .expel => |value| try world_tree.expelInPlace(self, value.node, value.direction),
            .remove_column => |id| try world_policy.removeColumnInPlace(self, id),
        }
    }

    fn applyGeometry(self: *World, item: command.Geometry) !void {
        switch (item) {
            .resize_column => |value| try world_policy.resizeColumnInPlace(self, value.column, value.width),
            .cycle_column_width => |value| try world_policy.cycleColumnWidthInPlace(self, value.column, value.step),
            .resize_split => |value| try world_policy.resizeSplitInPlace(self, value.split, value.child, value.weight),
            .move_floating => |value| try world_policy.moveFloatingInPlace(self, value.window, value.delta),
            .resize_floating => |value| try world_policy.resizeFloatingInPlace(self, value.window, value.edges, value.delta),
            .set_camera_target => |value| try world_policy.setCameraTargetInPlace(self, value.tag, value.target),
        }
    }

    fn applyTag(self: *World, item: command.Tag) !void {
        switch (item) {
            .activate => |value| try world_policy.setActiveTagInPlace(self, value.output, value.tag),
            .toggle => |value| try world_policy.toggleActiveTagInPlace(self, value.output, value.tag),
            .rename => |value| try world_policy.renameTagInPlace(self, value.tag, value.name),
            .remove => |id| try world_policy.removeTagInPlace(self, id),
        }
    }

    fn applyMark(self: *World, item: command.Mark) !void {
        switch (item) {
            .set => |value| try world_policy.setMarkInPlace(self, value.window, value.name),
            .clear => |value| try world_policy.clearMarkInPlace(self, value.window, value.name),
        }
    }

    fn applyTransfer(self: *World, item: command.Transfer) !void {
        switch (item) {
            .send_window => |value| try world_policy.sendWindowInPlace(self, value),
            .send_focused => |value| try world_policy.sendFocusedWindowInPlace(self, value.source_output, value.tag, value.output),
            .summon_window => |value| try world_policy.summonWindowInPlace(self, value.window, value.output),
            .summon_mark => |value| try world_policy.summonMarkInPlace(self, value.name, value.output),
        }
    }

    fn applyOutput(self: *World, item: command.Output) !void {
        switch (item) {
            .update => |value| try world_policy.updateOutputInPlace(self, value.output, .{
                .active_tag = value.active_tag,
                .bounds = value.bounds,
                .usable = value.usable,
                .configuration = value.configuration,
            }),
            .configure => |value| try world_policy.configureOutputInPlace(self, value.output, value.configuration),
            .remove => |id| try world_policy.removeOutputInPlace(self, id),
        }
    }

    fn applyWindow(self: *World, item: command.Window) !void {
        switch (item) {
            .set_output => |value| try world_policy.setWindowOutputInPlace(self, value.window, value.output),
            .set_placement => |value| try world_policy.setPlacementInPlace(self, value.window, value.placement),
            .transition_placement => |value| try world_policy.transitionPlacementInPlace(self, value.window, value.transition),
            .begin_close => |id| try self.beginCloseInPlace(id),
            .destroy => |id| try world_tree.destroyWindowInPlace(self, id),
        }
    }

    fn requireTag(self: *const World, id: TagId) !void {
        if (self.tags.getConst(id) == null) return error.UnknownTag;
    }

    fn requireOutput(self: *const World, id: OutputId) !void {
        if (self.outputs.getConst(id) == null) return error.UnknownOutput;
    }
};

pub const WorldView = snapshot_mod.View(World);
pub const WorldCheckpoint = snapshot_mod.Checkpoint(World);
