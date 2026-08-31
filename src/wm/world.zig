//! Authoritative WM policy state and its structural transaction boundary.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");
const command = @import("command.zig");
const world_apply = @import("world/apply.zig");
const snapshot_mod = @import("world/snapshot.zig");
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

    /// Initialize an empty policy world.
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

    /// Release all policy objects owned by this world.
    pub fn deinit(self: *World) void {
        self.window_index.deinit();
        self.nodes.deinit();
        self.columns.deinit();
        self.tags.deinit();
        self.outputs.deinit();
        self.windows.deinit();
        self.* = undefined;
    }

    /// Return the revision of the current policy state.
    pub fn epoch(self: *const World) u64 {
        return self.epoch_value;
    }

    /// Create an unnamed tag.
    pub fn createTag(self: *World) !TagId {
        self.assertValid();
        const id = try self.tags.insert(.{ .id = undefined });
        self.advanceEpoch();
        self.assertValid();
        std.debug.assert(self.getTag(id) != null);
        return id;
    }

    /// Create a tag with an owned, validated name.
    pub fn createNamedTag(self: *World, name: []const u8) !TagId {
        self.assertValid();
        try validation.validateName(name);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const id = try self.tags.insert(.{ .id = undefined, .name = owned });
        self.advanceEpoch();
        self.assertValid();
        std.debug.assert(std.mem.eql(u8, self.getTag(id).?.name, name));
        return id;
    }

    /// Create an output attached to an existing active tag.
    pub fn createOutput(self: *World, spec: OutputSpec) !OutputId {
        self.assertValid();
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
        self.assertValid();
        std.debug.assert(self.getOutput(id) != null);
        return id;
    }

    /// Append a column to an existing tag.
    pub fn createColumn(self: *World, tag_id: TagId, spec: ColumnSpec) !ColumnId {
        self.assertValid();
        const id = try world_tree.createColumnAt(self, tag_id, world_tree.tagColumnCount(self, tag_id) orelse return error.UnknownTag, spec, false);
        self.advanceEpoch();
        self.assertValid();
        std.debug.assert(self.getColumn(id) != null);
        return id;
    }

    /// Insert a column immediately after another column on the same tag.
    /// A null predecessor appends it. This is the semantic operation used by
    /// scrolling policy when a newly managed window follows current focus.
    pub fn createColumnAfter(self: *World, tag_id: TagId, predecessor: ?ColumnId, spec: ColumnSpec) !ColumnId {
        self.assertValid();
        const tag = self.tags.getConst(tag_id) orelse return error.UnknownTag;
        var index = tag.columns.items.len;
        if (predecessor) |wanted| {
            const column = self.columns.getConst(wanted) orelse return error.UnknownColumn;
            if (column.tag != tag_id) return error.TagMismatch;
            for (tag.columns.items, 0..) |candidate, ordinal| {
                if (candidate == wanted) {
                    index = ordinal + 1;
                    break;
                }
            } else return error.InvalidInvariant;
        }
        const id = try world_tree.createColumnAt(self, tag_id, index, spec, true);
        self.advanceEpoch();
        self.assertValid();
        return id;
    }

    /// Announce a window without inserting it into the layout tree.
    pub fn createWindow(self: *World, spec: WindowSpec) !WindowId {
        self.assertValid();
        try self.requireTag(spec.tag);
        try validation.validateFloatingGeometry(spec.floating_geometry);
        try validation.validateSizeHints(spec.size_hints);
        try validation.validateOptionalSize(spec.actual_size);
        try validation.validateOptionalSize(spec.proposed_size);
        if (spec.output) |output_id| try self.requireOutput(output_id);
        const id = try self.windows.insert(.{
            .id = undefined,
            .tag = spec.tag,
            .output = spec.output,
            .lifecycle = .announced,
            .placement = spec.placement,
            .floating_geometry = spec.floating_geometry,
            .size_hints = spec.size_hints,
            .actual_size = spec.actual_size,
            .proposed_size = spec.proposed_size,
        });
        self.advanceEpoch();
        self.assertValid();
        std.debug.assert(self.getWindow(id).?.lifecycle == .announced);
        return id;
    }

    /// Insert an announced window into a column and make it managed. An
    /// omitted column chooses the first column for the window's tag, creating
    /// a default column when the tag is empty.
    pub fn manageWindow(self: *World, window_id: WindowId, maybe_column: ?ColumnId) !void {
        self.assertValid();
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
        self.assertValid();
        std.debug.assert(self.nodeForWindow(window_id) != null);
    }

    pub fn wrapNode(self: *World, node_id: NodeId, mode: ContainerMode, axis: Axis) !NodeId {
        self.assertValid();
        // The command surface has no result channel. This direct structural
        // helper is useful to hosts that already own the new container id.
        const id = try world_tree.wrapNodeInPlace(self, node_id, mode, axis);
        self.advanceEpoch();
        self.assertValid();
        std.debug.assert(self.getNode(id) != null);
        return id;
    }

    /// Borrow a read-only view of the current world.
    pub fn view(self: *const World) WorldView {
        self.assertValid();
        return WorldView.init(self);
    }

    /// Capture an immutable checkpoint of the current world.
    pub fn checkpoint(self: *const World) !WorldCheckpoint {
        self.assertValid();
        return WorldCheckpoint.init(self);
    }

    /// Deep-copy policy state for persistence by an outer layer.
    pub fn saveState(self: *const World) !PersistenceState {
        self.assertValid();
        return .{ .world = try self.cloneState() };
    }

    /// Replace this world with a saved policy state and advance its revision.
    pub fn restoreState(self: *World, saved: *const PersistenceState) !void {
        self.assertValid();
        try saved.world.validate();
        const previous_epoch = self.epoch_value;
        var restored = try saved.world.cloneState();
        restored.epoch_value = previous_epoch +% 1;
        var previous = self.*;
        self.* = restored;
        previous.deinit();
        self.assertValid();
        std.debug.assert(self.epoch_value == previous_epoch +% 1);
    }

    /// Apply a complete semantic batch atomically. No failed command can
    /// leak an earlier successful command into the live world.
    pub fn applyAtomically(self: *World, commands: command.Batch) !ApplyResult {
        self.assertValid();
        if (commands.len == 0) return .{ .epoch = self.epoch_value, .changed = false };

        const previous_epoch = self.epoch_value;
        var candidate = try self.cloneState();
        errdefer candidate.deinit();
        for (commands) |item| try world_apply.one(&candidate, item);
        try candidate.validate();
        candidate.epoch_value = self.epoch_value +% 1;

        var previous = self.*;
        self.* = candidate;
        previous.deinit();
        self.assertValid();
        std.debug.assert(self.epoch_value == previous_epoch +% 1);
        return .{ .epoch = self.epoch_value, .changed = true };
    }

    fn advanceEpoch(self: *World) void {
        const previous = self.epoch_value;
        self.epoch_value +%= 1;
        std.debug.assert(self.epoch_value == previous +% 1);
    }

    /// Check every tree, index, lifecycle, and reciprocal-link invariant.
    pub fn validate(self: *const World) !void {
        try validation.validate(self);
    }

    /// Resolve an output identity.
    pub fn getOutput(self: *const World, id: OutputId) ?*const Output {
        return self.outputs.getConst(id);
    }

    /// Resolve a tag identity.
    pub fn getTag(self: *const World, id: TagId) ?*const Tag {
        return self.tags.getConst(id);
    }

    /// Return the dense ordinal of a live tag.
    pub fn tagOrdinal(self: *const World, id: TagId) ?usize {
        var ordinal: usize = 0;
        for (self.tags.slots.items) |slot| {
            const tag = slot.value orelse continue;
            if (tag.id == id) return ordinal;
            ordinal += 1;
        }
        return null;
    }

    /// Resolve a dense tag ordinal to its identity.
    pub fn tagAt(self: *const World, target: usize) ?TagId {
        var ordinal: usize = 0;
        for (self.tags.slots.items) |slot| {
            const tag = slot.value orelse continue;
            if (ordinal == target) return tag.id;
            ordinal += 1;
        }
        return null;
    }

    /// Return the first live output in storage order.
    pub fn firstOutput(self: *const World) ?OutputId {
        for (self.outputs.slots.items) |slot| if (slot.value) |output| return output.id;
        return null;
    }

    pub fn outputAt(self: *const World, target: usize) ?OutputId {
        var ordinal: usize = 0;
        for (self.outputs.slots.items) |slot| {
            const output = slot.value orelse continue;
            if (ordinal == target) return output.id;
            ordinal += 1;
        }
        return null;
    }

    pub fn liveOutputCount(self: *const World) usize {
        return self.outputs.liveCount();
    }

    /// Return the number of live tags.
    pub fn liveTagCount(self: *const World) usize {
        return self.tags.liveCount();
    }

    /// Resolve a column identity.
    pub fn getColumn(self: *const World, id: ColumnId) ?*const Column {
        return self.columns.getConst(id);
    }

    /// Resolve a layout-node identity.
    pub fn getNode(self: *const World, id: NodeId) ?*const Node {
        return self.nodes.getConst(id);
    }

    /// Resolve a window identity.
    pub fn getWindow(self: *const World, id: WindowId) ?*const Window {
        return self.windows.getConst(id);
    }

    /// Return the layout node that contains a managed window.
    pub fn nodeForWindow(self: *const World, id: WindowId) ?NodeId {
        return self.window_index.get(id);
    }

    /// Borrow a tag's ordered column identities.
    pub fn tagColumns(self: *const World, id: TagId) ?[]const ColumnId {
        const value = self.tags.getConst(id) orelse return null;
        return value.columns.items;
    }

    /// Return the number of live layout nodes.
    pub fn liveNodeCount(self: *const World) usize {
        return self.nodes.liveCount();
    }

    /// Return the number of live windows.
    pub fn liveWindowCount(self: *const World) usize {
        return self.windows.liveCount();
    }

    /// Return the number of live columns.
    pub fn liveColumnCount(self: *const World) usize {
        return self.columns.liveCount();
    }

    /// Deep-copy all state while preserving identities and revision.
    pub fn cloneState(self: *const World) !World {
        self.assertValid();
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
        copy.assertValid();
        std.debug.assert(copy.epoch_value == self.epoch_value);
        return copy;
    }

    fn assertValid(self: *const World) void {
        if (!std.debug.runtime_safety) return;
        validation.validate(self) catch unreachable;
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
