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
    try syncWindowMetadata(self);
    try syncWindowSizing(self);
    try applyWindowPolicy(self);
    if (focus) |window| if (self.objects.windows.get(window)) |record| {
        if (record.wm_id) |id| try focusIfFocusable(self, id);
    };
    removeRetiredSeats(self, facts);
    removeClosedRecords(self);
}

/// Compositor-originated focus (pointer interaction, new windows) can name a
/// window the model considers invisible, e.g. on another tag or minimized.
/// That is not a fault; the request is dropped and focus stays put.
fn focusIfFocusable(self: anytype, id: anytype) !void {
    _ = self.world.applyAtomically(&.{.{ .focus = .{ .window = id } }}) catch |err| switch (err) {
        error.NotFocusable => return logUnfocusable(self, id),
        else => return err,
    };
}

fn logUnfocusable(self: anytype, id: anytype) void {
    const window = self.world.getWindow(id) orelse {
        std.log.warn("focus dropped: window {d} unknown", .{id.raw()});
        return;
    };
    const output_id = self.world.windowOutput(id);
    const output = if (output_id) |shown| self.world.getOutput(shown) else null;
    std.log.warn(
        "focus dropped: window={d} lifecycle={s} placement={s} tag={d} output={?d} output_active_tag={?d} focused={?d}",
        .{
            id.raw(),
            @tagName(window.lifecycle),
            @tagName(window.placement),
            window.tag.raw(),
            if (output_id) |o| o.raw() else null,
            if (output) |o| o.active_tag.raw() else null,
            if (self.world.focusedWindow()) |w| w.raw() else null,
        },
    );
}

fn destroyClosedWindows(self: anytype) !void {
    var iterator = self.objects.windows.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value_ptr.closed) continue;
        if (entry.value_ptr.wm_id) |id| {
            try destroyWindow(self, id);
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
                _ = self.world.getWindow(window_id) orelse return error.UnknownWindow;
                if (self.world.windowOutput(window_id) != removed_output) continue;
                try destroyWindow(self, window_id);
                std.debug.assert(self.objects.wm_to_window.remove(window_id));
                entry.wm_id = null;
            }
            _ = try self.world.applyAtomically(&.{.{ .output = .{ .remove = removed_output } }});
            std.debug.assert(self.objects.wm_to_output.remove(removed_output));
            if (record.owns_tag) if (record.tag) |tag| {
                _ = try self.world.applyAtomically(&.{.{ .tag = .{ .remove = tag } }});
            };
        }
        std.debug.assert(self.objects.outputs.remove(id));
        _ = self.objects.output_order.orderedRemove(index);
    }
}

fn materializeWindows(self: anytype) !void {
    var admitted = false;
    // The remembered membership is for the windows River already had when we
    // started; once that first batch is placed it has served its purpose.
    defer if (admitted) if (self.restored) |*restored| {
        restored.deinit();
        self.restored = null;
    };
    for (self.objects.window_order.items) |window| {
        const entry = self.objects.windows.getPtr(window) orelse continue;
        if (entry.closed or entry.wm_id != null) continue;
        const destination = preferredOrFocusedOutput(self, entry.preferred_output) orelse return;
        const output_record = self.objects.outputs.get(destination).?;
        const output_value = self.world.getOutput(output_record.wm_id.?) orelse return error.UnknownOutput;
        // A window seen in the previous session goes back to its tag; anything else
        // opens on the focused monitor's tag.
        const restored_tag = restoredTag(self, entry.identifier.slice());
        const active_tag = restored_tag orelse output_value.active_tag;
        // New-window grouping and floating heuristics belong to the retained
        // Lua controller. Native reconciliation only establishes a neutral
        // managed window record from compositor facts.
        const placement = entry.requested_placement orelse .unplaced;
        const floating_geometry = initialFloatingGeometry(entry, output_value.usable);
        const result = try wm.lifecycle.applyEvent(&self.world, .{ .window_announced = .{
            .tag = active_tag,
            .transient = entry.parent != null,
            .identifier = entry.identifier,
            .placement = placement,
            .floating_geometry = floating_geometry,
            .size_hints = entry.dimensions_hint,
            .actual_size = wmSize(entry.actual_size),
            .proposed_size = wmSize(entry.last_proposed_size),
        } });
        const window_id = result.announced_window.?;
        _ = try wm.lifecycle.applyEvent(&self.world, .{ .window_managed = window_id });
        // Remembered windows keep whatever focus they had; new ones take it.
        const remembered = restored_tag != null;
        const was_focused = if (self.restored) |restored| restored.isFocus(entry.identifier.slice()) else false;
        if (!remembered or was_focused) try focusIfFocusable(self, window_id);
        entry.wm_id = window_id;
        admitted = true;
        entry.requested_placement = null;
        try self.objects.wm_to_window.put(window_id, window);
    }
}

fn restoredTag(self: anytype, identifier: []const u8) ?wm.TagId {
    const restored = self.restored orelse return null;
    if (identifier.len == 0) return null;
    const ordinal = restored.tagFor(identifier) orelse return null;
    return self.world.tagAt(ordinal - 1);
}

fn syncWindowMetadata(self: anytype) !void {
    var iterator = self.objects.windows.iterator();
    while (iterator.next()) |entry| {
        const id = entry.value_ptr.wm_id orelse continue;
        const current = self.world.getWindow(id) orelse return error.UnknownWindow;
        const transient = entry.value_ptr.parent != null;
        if (current.transient == transient) continue;
        _ = try self.world.applyAtomically(&.{.{ .window = .{ .set_transient = .{
            .window = id,
            .transient = transient,
        } } }});
    }
}

fn syncWindowSizing(self: anytype) !void {
    var iterator = self.objects.windows.iterator();
    while (iterator.next()) |entry| {
        const id = entry.value_ptr.wm_id orelse continue;
        const current = self.world.getWindow(id) orelse return error.UnknownWindow;
        const actual = wmSize(entry.value_ptr.actual_size);
        const proposed = wmSize(entry.value_ptr.last_proposed_size);
        var effective_hints = entry.value_ptr.dimensions_hint;
        effective_hints.min.width = @max(effective_hints.min.width, entry.value_ptr.confirmed_minimum.width);
        effective_hints.min.height = @max(effective_hints.min.height, entry.value_ptr.confirmed_minimum.height);
        if (effective_hints.max.width != 0)
            effective_hints.max.width = @max(effective_hints.max.width, effective_hints.min.width);
        if (effective_hints.max.height != 0)
            effective_hints.max.height = @max(effective_hints.max.height, effective_hints.min.height);
        if (std.meta.eql(current.size_hints, effective_hints) and
            std.meta.eql(current.actual_size, actual) and
            std.meta.eql(current.proposed_size, proposed)) continue;
        _ = try self.world.applyAtomically(&.{.{ .window = .{ .update_sizing = .{
            .window = id,
            .hints = effective_hints,
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
        const destination_tag = (self.world.getOutput(destination_wm) orelse return error.UnknownOutput).active_tag;
        // The hint is one-shot: honoring it once must not fight later moves
        // (e.g. send-to-tag) by dragging the window back every cycle.
        entry.preferred_output = null;
        if (current.tag == destination_tag) continue;
        _ = try self.world.applyAtomically(&.{.{ .window = .{ .assign = .{
            .window = window_id,
            .tag = destination_tag,
        } } }});
    }
}

fn destroyWindow(self: anytype, window_id: wm.WindowId) !void {
    _ = try self.world.applyAtomically(&.{.{ .window = .{ .destroy = window_id } }});
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

/// New windows open where the client asked, else on the focused monitor.
fn preferredOrFocusedOutput(self: anytype, preferred: ?types.OutputId) ?types.OutputId {
    if (preferred == null) if (self.world.focusedOutput()) |focused| {
        if (self.objects.wm_to_output.get(focused)) |id| if (self.objects.outputs.get(id)) |record| {
            if (!record.removed and record.wm_id != null) return id;
        };
    };
    return preferredOrFirstOutput(self, preferred);
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
