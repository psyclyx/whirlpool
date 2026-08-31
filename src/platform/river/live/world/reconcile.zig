//! Mandatory River object-lifecycle reconciliation into the WM kernel.

const std = @import("std");
const host = @import("whirlpool-host");
const wm = @import("whirlpool-wm");

const types = host.types;

pub fn run(self: anytype, facts: []const types.ManageFact) !void {
    var focus: ?types.WindowId = null;
    for (facts) |fact| switch (fact) {
        .output_position => |value| self.objects.outputs.getPtr(value.output).?.position = value.position,
        .output_dimensions => |value| self.objects.outputs.getPtr(value.output).?.dimensions = value.size,
        .output_removed => |id| self.objects.outputs.getPtr(id).?.removed = true,
        .window_closed => |id| self.objects.windows.getPtr(id).?.closed = true,
        .window_fullscreen_requested => |value| {
            const record = self.objects.windows.getPtr(value.window).?;
            record.requested_placement = .fullscreen;
            record.preferred_output = value.output;
        },
        .window_exit_fullscreen_requested, .window_unmaximize_requested => |id| self.objects.windows.getPtr(id).?.requested_placement = .tiled,
        .window_maximize_requested => |id| self.objects.windows.getPtr(id).?.requested_placement = .tiled,
        .window_minimize_requested => |id| self.objects.windows.getPtr(id).?.requested_placement = .scratchpad,
        .seat_window_interaction => |value| focus = value.window,
        else => {},
    };

    try destroyClosedWindows(self);
    try reconcileOutputs(self);
    try removeRetiredOutputs(self);
    try moveWindowsToPreferredOutputs(self);
    try materializeWindows(self);
    try syncWindowSizing(self);
    try applyWindowPolicy(self);
    if (focus) |window| if (self.objects.windows.get(window)) |record| {
        if (record.wm_id) |id| _ = try self.world.applyAtomically(&.{.{ .focus = .{ .window = id } }});
    };
    removeRetiredSeats(self, facts);
    removeClosedRecords(self);
}

fn destroyClosedWindows(self: anytype) !void {
    var iterator = self.objects.windows.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value_ptr.closed) continue;
        if (entry.value_ptr.wm_id) |id| {
            try destroyWindowAndEmptyColumn(self, id);
            std.debug.assert(self.objects.wm_to_window.remove(id));
            entry.value_ptr.wm_id = null;
        }
    }
}

fn reconcileOutputs(self: anytype) !void {
    var output_ordinal: usize = 0;
    for (self.objects.output_order.items) |id| {
        const record = self.objects.outputs.getPtr(id) orelse continue;
        if (record.removed) continue;
        defer output_ordinal += 1;
        const position = record.position orelse return error.IncompleteOutput;
        const size = record.dimensions orelse return error.IncompleteOutput;
        if (record.wm_id) |output_id| {
            const active_tag = (self.world.getOutput(output_id) orelse return error.UnknownOutput).active_tag;
            var spec = try outputSpec(position, size, record.usable, active_tag);
            try reserveShellArea(self, &spec);
            _ = try wm.lifecycle.applyEvent(&self.world, .{ .output_reconciled = .{
                .output = output_id,
                .active_tag = active_tag,
                .bounds = spec.bounds,
                .usable = spec.usable,
            } });
        } else {
            var owns_tag = false;
            const tag = self.world.tagAt(output_ordinal) orelse blk: {
                owns_tag = true;
                const result = try wm.lifecycle.applyEvent(&self.world, .tag_announced);
                break :blk result.announced_tag.?;
            };
            var spec = try outputSpec(position, size, record.usable, tag);
            try reserveShellArea(self, &spec);
            const created = try wm.lifecycle.applyEvent(&self.world, .{ .output_announced = .{
                .active_tag = tag,
                .bounds = spec.bounds,
                .usable = spec.usable,
            } });
            const output_id = created.announced_output.?;
            record.tag = tag;
            record.owns_tag = owns_tag;
            record.wm_id = output_id;
            try self.objects.wm_to_output.put(output_id, id);
        }
    }
}

fn reserveShellArea(self: anytype, spec: *wm.OutputSpec) !void {
    if (self.reserved_bottom == 0) return;
    if (spec.usable.height <= self.reserved_bottom) return error.InvalidDimensions;
    spec.usable.height -= self.reserved_bottom;
}

fn removeRetiredOutputs(self: anytype) !void {
    var index: usize = 0;
    while (index < self.objects.output_order.items.len) {
        const id = self.objects.output_order.items[index];
        const record = self.objects.outputs.get(id) orelse {
            _ = self.objects.output_order.orderedRemove(index);
            continue;
        };
        if (!record.removed) {
            index += 1;
            continue;
        }

        if (record.wm_id) |removed_output| {
            for (self.objects.window_order.items) |window| {
                const entry = self.objects.windows.getPtr(window) orelse continue;
                const window_id = entry.wm_id orelse continue;
                const value = self.world.getWindow(window_id) orelse return error.UnknownWindow;
                if (value.output != removed_output) continue;
                try destroyWindowAndEmptyColumn(self, window_id);
                std.debug.assert(self.objects.wm_to_window.remove(window_id));
                entry.wm_id = null;
            }
            _ = try self.world.applyAtomically(&.{.{ .output = .{ .remove = removed_output } }});
            std.debug.assert(self.objects.wm_to_output.remove(removed_output));
            if (record.owns_tag) if (record.tag) |tag| {
                while (self.world.tagColumns(tag)) |columns| {
                    if (columns.len == 0) break;
                    _ = try self.world.applyAtomically(&.{.{ .tree = .{ .remove_column = columns[0] } }});
                }
                _ = try self.world.applyAtomically(&.{.{ .tag = .{ .remove = tag } }});
            };
        }
        std.debug.assert(self.objects.outputs.remove(id));
        _ = self.objects.output_order.orderedRemove(index);
    }
}

fn materializeWindows(self: anytype) !void {
    for (self.objects.window_order.items) |window| {
        const entry = self.objects.windows.getPtr(window) orelse continue;
        if (entry.closed or entry.wm_id != null) continue;
        const destination = preferredOrFirstOutput(self, entry.preferred_output) orelse return;
        const output_record = self.objects.outputs.get(destination).?;
        const output_value = self.world.getOutput(output_record.wm_id.?) orelse return error.UnknownOutput;
        const active_tag = output_value.active_tag;
        const placement = entry.requested_placement orelse defaultPlacement(self, entry);
        const floating_geometry = initialFloatingGeometry(entry, output_value.usable);
        const result = try wm.lifecycle.applyEvent(&self.world, .{ .window_announced = .{
            .tag = active_tag,
            .output = output_record.wm_id.?,
            .placement = placement,
            .floating_geometry = floating_geometry,
            .size_hints = entry.dimensions_hint,
            .actual_size = wmSize(entry.actual_size),
            .proposed_size = wmSize(entry.last_proposed_size),
        } });
        const window_id = result.announced_window.?;
        const tag = self.world.getTag(active_tag) orelse return error.UnknownTag;
        const focused_column = if (tag.focused) |node|
            (self.world.getNode(node) orelse return error.InvalidInvariant).column
        else
            null;
        // Tidepool's scrolling policy gives every newly tiled window its own
        // 50% column immediately after the focused column. Structural absorb
        // actions are what intentionally combine windows later.
        const column = try self.world.createColumnAfter(active_tag, focused_column, .{ .width = 0.5 });
        _ = try wm.lifecycle.applyEvent(&self.world, .{ .window_managed = .{ .window = window_id, .column = column } });
        _ = try self.world.applyAtomically(&.{.{ .focus = .{ .window = window_id } }});
        entry.wm_id = window_id;
        entry.requested_placement = null;
        try self.objects.wm_to_window.put(window_id, window);
    }
}

fn syncWindowSizing(self: anytype) !void {
    var iterator = self.objects.windows.iterator();
    while (iterator.next()) |entry| {
        const id = entry.value_ptr.wm_id orelse continue;
        const current = self.world.getWindow(id) orelse return error.UnknownWindow;
        const actual = wmSize(entry.value_ptr.actual_size);
        const proposed = wmSize(entry.value_ptr.last_proposed_size);
        if (std.meta.eql(current.size_hints, entry.value_ptr.dimensions_hint) and
            std.meta.eql(current.actual_size, actual) and
            std.meta.eql(current.proposed_size, proposed)) continue;
        _ = try self.world.applyAtomically(&.{.{ .window = .{ .update_sizing = .{
            .window = id,
            .hints = entry.value_ptr.dimensions_hint,
            .actual = actual,
            .proposed = proposed,
        } } }});
    }
}

fn moveWindowsToPreferredOutputs(self: anytype) !void {
    for (self.objects.window_order.items) |window| {
        const entry = self.objects.windows.getPtr(window) orelse continue;
        const preferred = entry.preferred_output orelse continue;
        const destination = self.objects.outputs.get(preferred) orelse continue;
        const destination_wm = destination.wm_id orelse continue;
        const window_id = entry.wm_id orelse continue;
        const current = self.world.getWindow(window_id) orelse return error.UnknownWindow;
        if (current.output == destination_wm) continue;
        try destroyWindowAndEmptyColumn(self, window_id);
        std.debug.assert(self.objects.wm_to_window.remove(window_id));
        entry.wm_id = null;
    }
}

fn destroyWindowAndEmptyColumn(self: anytype, window_id: wm.WindowId) !void {
    const node_id = self.world.nodeForWindow(window_id) orelse return error.UnknownWindow;
    const node = self.world.getNode(node_id) orelse return error.InvalidInvariant;
    const column = self.world.getColumn(node.column) orelse return error.InvalidInvariant;
    if (column.root == node_id) {
        _ = try self.world.applyAtomically(&.{
            .{ .window = .{ .destroy = window_id } },
            .{ .tree = .{ .remove_column = node.column } },
        });
    } else {
        _ = try self.world.applyAtomically(&.{.{ .window = .{ .destroy = window_id } }});
    }
}

fn applyWindowPolicy(self: anytype) !void {
    var iterator = self.objects.windows.iterator();
    while (iterator.next()) |entry| {
        const id = entry.value_ptr.wm_id orelse continue;
        const requested = entry.value_ptr.requested_placement orelse continue;
        const current = self.world.getWindow(id) orelse return error.UnknownWindow;
        if (current.placement != requested) _ = try self.world.applyAtomically(&.{.{ .window = .{ .set_placement = .{
            .window = id,
            .placement = requested,
        } } }});
        entry.value_ptr.requested_placement = null;
    }
}

fn defaultPlacement(self: anytype, record: anytype) wm.Placement {
    if (record.parent) |parent| if (self.objects.windows.get(parent)) |value|
        if (!value.closed) return .floating;
    if (likelyFixedSize(record) or likelyConstrainedDialog(record)) return .floating;
    return .tiled;
}

fn likelyFixedSize(record: anytype) bool {
    if (record.dimensions_hint.fixed() != null) return true;
    const actual = wmSize(record.actual_size) orelse return false;
    const minimum = record.dimensions_hint.min;
    return minimum.width > 0 and minimum.height > 0 and std.meta.eql(minimum, actual);
}

fn likelyConstrainedDialog(record: anytype) bool {
    const hints = record.dimensions_hint;
    if (hints.max.width > 0 and hints.max.height > 0) {
        if (hints.max.width < 1600 and hints.max.height < 1200) return true;
        if (hints.min.width > 0 and hints.min.height > 0 and
            @as(u64, hints.min.width) * 2 >= hints.max.width and
            @as(u64, hints.min.height) * 2 >= hints.max.height) return true;
    }
    const actual = wmSize(record.actual_size) orelse return false;
    return record.decoration_hint == .only_supports_csd and
        actual.width < 1200 and actual.height < 900;
}

fn initialFloatingGeometry(record: anytype, usable: wm.Rect) wm.Rect {
    const fixed = record.dimensions_hint.fixed();
    const actual = wmSize(record.actual_size);
    const preferred = actual orelse fixed orelse wm.Size{
        .width = if (record.dimensions_hint.max.width != 0) record.dimensions_hint.max.width else 640,
        .height = if (record.dimensions_hint.max.height != 0) record.dimensions_hint.max.height else 480,
    };
    const width = @max(@as(u32, 1), @min(preferred.width, usable.width));
    const height = @max(@as(u32, 1), @min(preferred.height, usable.height));
    return .{
        .x = usable.x + @as(i32, @intCast((usable.width - width) / 2)),
        .y = usable.y + @as(i32, @intCast((usable.height - height) / 2)),
        .width = width,
        .height = height,
    };
}

fn wmSize(value: ?types.Size) ?wm.Size {
    const size = value orelse return null;
    if (size.width <= 0 or size.height <= 0) return null;
    return .{ .width = @intCast(size.width), .height = @intCast(size.height) };
}

fn removeRetiredSeats(self: anytype, facts: []const types.ManageFact) void {
    for (facts) |fact| switch (fact) {
        .seat_removed => |id| std.debug.assert(self.objects.seats.remove(id)),
        else => {},
    };
}

fn removeClosedRecords(self: anytype) void {
    var index: usize = 0;
    while (index < self.objects.window_order.items.len) {
        const id = self.objects.window_order.items[index];
        const record = self.objects.windows.get(id) orelse {
            _ = self.objects.window_order.orderedRemove(index);
            continue;
        };
        if (!record.closed) {
            index += 1;
            continue;
        }
        self.objects.windows.getPtr(id).?.deinit(self.objects.allocator);
        std.debug.assert(self.objects.windows.remove(id));
        _ = self.objects.window_order.orderedRemove(index);
    }
}

fn preferredOrFirstOutput(self: anytype, preferred: ?types.OutputId) ?types.OutputId {
    if (preferred) |id| if (self.objects.outputs.get(id)) |record| {
        if (!record.removed and record.wm_id != null) return id;
    };
    for (self.objects.output_order.items) |id| {
        const record = self.objects.outputs.get(id) orelse continue;
        if (!record.removed and record.wm_id != null) return id;
    }
    return null;
}

pub fn outputSpec(position: types.Point, size: types.Size, usable: ?wm.Rect, maybe_tag: ?wm.TagId) !wm.OutputSpec {
    if (size.width <= 0 or size.height <= 0) return error.InvalidDimensions;
    return .{
        .active_tag = maybe_tag orelse wm.TagId.invalid,
        .bounds = .{ .x = position.x, .y = position.y, .width = @intCast(size.width), .height = @intCast(size.height) },
        .usable = usable orelse .{ .x = position.x, .y = position.y, .width = @intCast(size.width), .height = @intCast(size.height) },
    };
}
