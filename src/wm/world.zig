//! Authoritative flat compositor resource state and transaction boundary.

const std = @import("std");
const ids = @import("ids.zig");
const types = @import("types.zig");
const command = @import("command.zig");
const world_apply = @import("world/apply.zig");
const snapshot_mod = @import("world/snapshot.zig");
const validation = @import("world/validation.zig");

pub const WindowId = ids.WindowId;
pub const OutputId = ids.OutputId;
pub const TagId = ids.TagId;
pub const Window = types.Window;
pub const Output = types.Output;
pub const Tag = types.Tag;
pub const WindowSpec = types.WindowSpec;
pub const OutputSpec = types.OutputSpec;
pub const OutputConfig = types.OutputConfig;
pub const OutputTransform = types.OutputTransform;
pub const Rect = types.Rect;
pub const ResizeEdges = types.ResizeEdges;
pub const Point = types.Point;
pub const Lifecycle = types.Lifecycle;
pub const Placement = types.Placement;
pub const PlacementTransition = types.PlacementTransition;
pub const Command = command.Command;

const WindowStore = ids.Store(Window, .window);
const OutputStore = ids.Store(Output, .output);
const TagStore = ids.Store(Tag, .tag);

pub const ApplyResult = struct { epoch: u64, changed: bool };
pub const PersistenceState = struct {
    world: World,

    pub fn deinit(self: *PersistenceState) void {
        self.world.deinit();
        self.* = undefined;
    }
};

pub const World = struct {
    allocator: std.mem.Allocator,
    epoch_value: u64 = 0,
    windows: WindowStore,
    outputs: OutputStore,
    tags: TagStore,
    focused: ?WindowId = null,
    /// The monitor last focused explicitly. A monitor can be focused with no
    /// window on it; while a window is focused its own output wins.
    focused_output: ?OutputId = null,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .windows = WindowStore.init(allocator),
            .outputs = OutputStore.init(allocator),
            .tags = TagStore.init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        self.tags.deinit();
        self.outputs.deinit();
        self.windows.deinit();
        self.* = undefined;
    }

    pub fn epoch(self: *const World) u64 {
        return self.epoch_value;
    }

    pub fn createTag(self: *World) !TagId {
        return self.createNamedTag("");
    }

    pub fn createNamedTag(self: *World, name: []const u8) !TagId {
        self.assertValid();
        try validation.validateOptionalName(name);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const id = try self.tags.insert(.{ .id = undefined, .name = owned });
        self.advanceEpoch();
        self.assertValid();
        return id;
    }

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
        return id;
    }

    pub fn createWindow(self: *World, spec: WindowSpec) !WindowId {
        self.assertValid();
        try self.requireTag(spec.tag);
        try validation.validateFloatingGeometry(spec.floating_geometry);
        try validation.validateSizeHints(spec.size_hints);
        try validation.validateOptionalSize(spec.actual_size);
        try validation.validateOptionalSize(spec.proposed_size);
        const id = try self.windows.insert(.{
            .id = undefined,
            .tag = spec.tag,
            .identifier = spec.identifier,
            .transient = spec.transient,
            .placement = spec.placement,
            .restore_placement = if (spec.placement == .floating) .floating else .tiled,
            .floating_geometry = spec.floating_geometry,
            .size_hints = spec.size_hints,
            .actual_size = spec.actual_size,
            .proposed_size = spec.proposed_size,
        });
        self.advanceEpoch();
        self.assertValid();
        return id;
    }

    pub fn manageWindow(self: *World, window: WindowId) !void {
        _ = try self.applyAtomically(&.{.{ .window = .{ .manage = window } }});
    }

    pub fn view(self: *const World) WorldView {
        self.assertValid();
        return WorldView.init(self);
    }

    pub fn checkpoint(self: *const World) !WorldCheckpoint {
        self.assertValid();
        return WorldCheckpoint.init(self);
    }

    pub fn saveState(self: *const World) !PersistenceState {
        self.assertValid();
        return .{ .world = try self.cloneState() };
    }

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
    }

    pub fn applyAtomically(self: *World, commands: command.Batch) !ApplyResult {
        self.assertValid();
        if (commands.len == 0) return .{ .epoch = self.epoch_value, .changed = false };
        var candidate = try self.cloneState();
        errdefer candidate.deinit();
        for (commands) |item| try world_apply.one(&candidate, item);
        try candidate.validate();
        candidate.epoch_value = self.epoch_value +% 1;
        var previous = self.*;
        self.* = candidate;
        previous.deinit();
        self.assertValid();
        return .{ .epoch = self.epoch_value, .changed = true };
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

    pub fn getWindow(self: *const World, id: WindowId) ?*const Window {
        return self.windows.getConst(id);
    }

    pub fn focusedWindow(self: *const World) ?WindowId {
        return self.focused;
    }

    /// The focused monitor: the output showing the focused window, else the one
    /// focused explicitly, else the first.
    pub fn focusedOutput(self: *const World) ?OutputId {
        if (self.focused) |window| if (self.windowOutput(window)) |output| return output;
        if (self.focused_output) |output| if (self.outputs.getConst(output) != null) return output;
        return self.firstOutput();
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
        return idAt(TagId, self.tags.slots.items, target);
    }

    pub fn outputAt(self: *const World, target: usize) ?OutputId {
        return idAt(OutputId, self.outputs.slots.items, target);
    }

    pub fn windowAt(self: *const World, target: usize) ?WindowId {
        return idAt(WindowId, self.windows.slots.items, target);
    }

    pub fn firstOutput(self: *const World) ?OutputId {
        return self.outputAt(0);
    }

    /// Whether some output currently shows `tag`.
    pub fn tagShownSomewhere(self: *const World, tag: TagId) bool {
        for (self.outputs.slots.items) |slot| {
            const output = slot.value orelse continue;
            if (output.active_tag == tag) return true;
        }
        return false;
    }

    /// The output a window is presented on: the one showing its tag. Windows
    /// carry no output of their own, so this cannot disagree with the tag.
    pub fn windowOutput(self: *const World, id: WindowId) ?OutputId {
        const window = self.getWindow(id) orelse return null;
        for (self.outputs.slots.items) |slot| {
            const output = slot.value orelse continue;
            if (output.active_tag == window.tag) return output.id;
        }
        return null;
    }

    pub fn liveOutputCount(self: *const World) usize {
        return self.outputs.liveCount();
    }

    pub fn liveTagCount(self: *const World) usize {
        return self.tags.liveCount();
    }

    pub fn liveWindowCount(self: *const World) usize {
        return self.windows.liveCount();
    }

    pub fn cloneState(self: *const World) !World {
        self.assertValid();
        var copy = World.init(self.allocator);
        errdefer copy.deinit();
        copy.epoch_value = self.epoch_value;
        copy.windows = try self.windows.clone();
        copy.outputs = try self.outputs.clone();
        copy.tags = try self.tags.clone();
        copy.focused = self.focused;
        copy.focused_output = self.focused_output;
        copy.assertValid();
        return copy;
    }

    fn advanceEpoch(self: *World) void {
        self.epoch_value +%= 1;
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

fn idAt(comptime Id: type, slots: anytype, target: usize) ?Id {
    var ordinal: usize = 0;
    for (slots) |slot| {
        const value = slot.value orelse continue;
        if (ordinal == target) return value.id;
        ordinal += 1;
    }
    return null;
}

pub const WorldView = snapshot_mod.View(World);
pub const WorldCheckpoint = snapshot_mod.Checkpoint(World);
