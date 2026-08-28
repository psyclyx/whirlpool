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
            record.desired_placement = .fullscreen;
            record.preferred_output = value.output;
        },
        .window_exit_fullscreen_requested, .window_unmaximize_requested => |id| self.objects.windows.getPtr(id).?.desired_placement = .tiled,
        .window_maximize_requested => |id| self.objects.windows.getPtr(id).?.desired_placement = .tiled,
        .window_minimize_requested => |id| self.objects.windows.getPtr(id).?.desired_placement = .scratchpad,
        .seat_window_interaction => |value| focus = value.window,
        else => {},
    };

    try destroyClosedWindows(self);
    try reconcileOutputs(self);
    try removeRetiredOutputs(self);
    try moveWindowsToPreferredOutputs(self);
    try materializeWindows(self);
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
            _ = try self.world.applyAtomically(&.{.{ .window = .{ .destroy = id } }});
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
                _ = try self.world.applyAtomically(&.{.{ .window = .{ .destroy = window_id } }});
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
        const active_tag = (self.world.getOutput(output_record.wm_id.?) orelse return error.UnknownOutput).active_tag;
        const result = try wm.lifecycle.applyEvent(&self.world, .{ .window_announced = .{
            .tag = active_tag,
            .output = output_record.wm_id.?,
            .placement = entry.desired_placement,
        } });
        const window_id = result.announced_window.?;
        const column = if (self.world.tagColumns(active_tag)) |columns|
            if (columns.len != 0) columns[0] else try self.world.createColumn(active_tag, .{})
        else
            return error.UnknownOutput;
        _ = try wm.lifecycle.applyEvent(&self.world, .{ .window_managed = .{ .window = window_id, .column = column } });
        entry.wm_id = window_id;
        try self.objects.wm_to_window.put(window_id, window);
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
        _ = try self.world.applyAtomically(&.{.{ .window = .{ .destroy = window_id } }});
        std.debug.assert(self.objects.wm_to_window.remove(window_id));
        entry.wm_id = null;
    }
}

fn applyWindowPolicy(self: anytype) !void {
    var iterator = self.objects.windows.iterator();
    while (iterator.next()) |entry| {
        const id = entry.value_ptr.wm_id orelse continue;
        const current = self.world.getWindow(id) orelse return error.UnknownWindow;
        if (current.placement == entry.value_ptr.desired_placement) continue;
        _ = try self.world.applyAtomically(&.{.{ .window = .{ .set_placement = .{
            .window = id,
            .placement = entry.value_ptr.desired_placement,
        } } }});
    }
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
