//! Retained flex layout over a `tree.Scene`.
//!
//! Rows and columns place their children along one axis, stacks overlay them.
//! A child's size along a row or column comes from its explicit size, else its
//! content (measured text, or the sum/maximum of its own children); `flex`
//! shares out leftover space, `shrink` takes back overflow, `justify` places
//! children when nothing flexes, and the container's `align` places them
//! across. Invisible nodes take no space. `min_*`/`max_*` bound every size.
//!
//! The pass is retained: each node keeps its box and measured size between
//! frames, a property change forgets only the measurements on its path to the
//! root, and nothing runs at all until something affecting geometry changes.
//! Offsets are not layout: they move an already placed subtree when painted,
//! so scrolling and sliding never re-run this pass.

const std = @import("std");
const tree = @import("tree.zig");
const properties = @import("properties.zig");

const Scene = tree.Scene;
const NodeHandle = tree.NodeHandle;
const Node = tree.Node;

pub const Size = struct { width: f32, height: f32 };
pub const Box = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: Box, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }

    pub fn inset(self: Box, edges: properties.Edges) Box {
        const left: f32 = @floatFromInt(edges.left);
        const right: f32 = @floatFromInt(edges.right);
        const top: f32 = @floatFromInt(edges.top);
        const bottom: f32 = @floatFromInt(edges.bottom);
        return .{
            .x = self.x + left,
            .y = self.y + top,
            .width = @max(0, self.width - left - right),
            .height = @max(0, self.height - top - bottom),
        };
    }
};

/// Text metrics, supplied by whatever renders the text so layout and drawing
/// agree on widths.
pub const Measurer = struct {
    context: ?*anyopaque = null,
    /// Advance width of `text` in font `family` (empty: the default) at
    /// font size `size`.
    width_fn: *const fn (?*anyopaque, []const u8, []const u8, f32) f32,
    /// Length in bytes of the longest prefix of `text`, ending on a character
    /// boundary, whose advance in `family` at `size` is at most `max_width`.
    fit_fn: *const fn (?*anyopaque, []const u8, []const u8, f32, f32) usize,

    pub fn width(self: Measurer, family: []const u8, text: []const u8, size: f32) f32 {
        return self.width_fn(self.context, family, text, size);
    }

    pub fn fit(self: Measurer, family: []const u8, text: []const u8, size: f32, max_width: f32) usize {
        return self.fit_fn(self.context, family, text, size, max_width);
    }

    /// A font-free approximation for tests and headless tools: every character
    /// is a fixed fraction of the font size wide.
    pub const estimate: Measurer = .{ .width_fn = estimateWidth, .fit_fn = estimateFit };

    const estimate_advance = 0.55;

    fn estimateWidth(_: ?*anyopaque, _: []const u8, text: []const u8, size: f32) f32 {
        return @as(f32, @floatFromInt(codepoints(text))) * size * estimate_advance;
    }

    fn estimateFit(_: ?*anyopaque, _: []const u8, text: []const u8, size: f32, max_width: f32) usize {
        const advance = size * estimate_advance;
        var used: f32 = 0;
        var index: usize = 0;
        while (index < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            if (used + advance > max_width) break;
            used += advance;
            index = @min(text.len, index + length);
        }
        return index;
    }

    fn codepoints(text: []const u8) usize {
        var count: usize = 0;
        for (text) |byte| {
            if (byte & 0xc0 != 0x80) count += 1;
        }
        return count;
    }
};

const Axis = enum(u1) {
    horizontal,
    vertical,

    fn other(self: Axis) Axis {
        return if (self == .horizontal) .vertical else .horizontal;
    }
};

const Pass = struct {
    scene: *Scene,
    measurer: Measurer,

    fn node(self: *const Pass, handle: NodeHandle) *const Node {
        return self.scene.get(handle) orelse unreachable;
    }

    /// Content-determined size of a node along `axis`, bounded by its limits.
    fn intrinsic(self: *Pass, handle: NodeHandle, axis: Axis) f32 {
        const current = self.node(handle);
        const cached = current.layout.intrinsic[@intFromEnum(axis)];
        if (!std.math.isNan(cached)) return cached;
        const value = self.measure(handle, axis);
        self.scene.getLayoutMut(handle).?.intrinsic[@intFromEnum(axis)] = value;
        return value;
    }

    fn measure(self: *Pass, handle: NodeHandle, axis: Axis) f32 {
        const current = self.node(handle);
        const p = current.props();
        if (!p.visible) return 0;
        if (explicit(p, axis)) |value| return bound(p, axis, value);
        const padding: f32 = @floatFromInt(if (axis == .horizontal)
            p.padding.left + p.padding.right
        else
            p.padding.top + p.padding.bottom);
        const content: f32 = switch (current.kind) {
            .text => if (p.text.len == 0)
                0
            else if (axis == .horizontal)
                @ceil(self.measurer.width(p.font_family, p.text, @floatFromInt(p.font_size)))
            else
                @floatFromInt(p.font_size),
            .row, .column, .stack => blk: {
                const along = (current.kind == .row and axis == .horizontal) or
                    (current.kind == .column and axis == .vertical);
                var total: f32 = 0;
                var largest: f32 = 0;
                var count: usize = 0;
                var child = current.first_child;
                while (child) |child_handle| : (child = self.node(child_handle).next_sibling) {
                    if (!self.node(child_handle).props().visible) continue;
                    const value = self.intrinsic(child_handle, axis);
                    total += value;
                    largest = @max(largest, value);
                    count += 1;
                }
                if (along and count > 1) total += @as(f32, @floatFromInt(p.gap)) * @as(f32, @floatFromInt(count - 1));
                break :blk if (along) total else largest;
            },
            .spacer, .shape, .polygon, .icon => 0,
        };
        return bound(p, axis, content + padding);
    }

    fn place(self: *Pass, handle: NodeHandle, box: Box) void {
        const state = self.scene.getLayoutMut(handle).?;
        state.x = box.x;
        state.y = box.y;
        state.width = box.width;
        state.height = box.height;
        const current = self.node(handle);
        const p = current.props();
        const content = box.inset(p.padding);
        switch (current.kind) {
            .row => self.flow(handle, content, .horizontal),
            .column => self.flow(handle, content, .vertical),
            .stack => {
                var child = current.first_child;
                while (child) |child_handle| : (child = self.node(child_handle).next_sibling) {
                    if (!self.node(child_handle).props().visible) continue;
                    self.place(child_handle, self.overlay(child_handle, content, p.@"align"));
                }
            },
            else => {},
        }
    }

    /// A stack child's box: its own size (or the whole content box when
    /// stretched), aligned on both axes.
    fn overlay(self: *Pass, handle: NodeHandle, content: Box, alignment: properties.Align) Box {
        const p = self.node(handle).props();
        const width = self.crossSize(handle, p, .horizontal, content.width, alignment);
        const height = self.crossSize(handle, p, .vertical, content.height, alignment);
        return snap(.{
            .x = content.x + alignOffset(alignment, content.width - width),
            .y = content.y + alignOffset(alignment, content.height - height),
            .width = width,
            .height = height,
        });
    }

    fn crossSize(self: *Pass, handle: NodeHandle, p: *const properties.Stored, axis: Axis, available: f32, alignment: properties.Align) f32 {
        if (explicit(p, axis)) |value| return bound(p, axis, value);
        if (alignment == .stretch) return bound(p, axis, available);
        return @min(self.intrinsic(handle, axis), @max(available, minimum(p, axis)));
    }

    fn flow(self: *Pass, parent: NodeHandle, content: Box, axis: Axis) void {
        const parent_node = self.node(parent);
        const p = parent_node.props();
        const main_available = if (axis == .horizontal) content.width else content.height;
        const cross_available = if (axis == .horizontal) content.height else content.width;
        const gap: f32 = @floatFromInt(p.gap);

        // First pass: base sizes and the totals that decide how leftover or
        // missing space is shared.
        var count: usize = 0;
        var used: f32 = 0;
        var flex_total: f32 = 0;
        var shrink_weight: f32 = 0;
        var child = parent_node.first_child;
        while (child) |handle| : (child = self.node(handle).next_sibling) {
            const cp = self.node(handle).props();
            if (!cp.visible) continue;
            count += 1;
            used += self.base(handle, cp, axis);
            flex_total += @floatFromInt(cp.flex);
            shrink_weight += @as(f32, @floatFromInt(cp.shrink)) * self.base(handle, cp, axis);
        }
        if (count == 0) return;
        used += gap * @as(f32, @floatFromInt(count - 1));
        const free = main_available - used;

        // Leftover space that nothing flexes into is placed by `justify`.
        var cursor = if (axis == .horizontal) content.x else content.y;
        var spacing = gap;
        if (free > 0 and flex_total == 0) switch (p.justify) {
            .start => {},
            .center => cursor += free / 2,
            .end => cursor += free,
            .between => if (count > 1) {
                spacing += free / @as(f32, @floatFromInt(count - 1));
            },
        };

        const cross_start = if (axis == .horizontal) content.y else content.x;
        child = parent_node.first_child;
        while (child) |handle| : (child = self.node(handle).next_sibling) {
            const cp = self.node(handle).props();
            if (!cp.visible) continue;
            var size = self.base(handle, cp, axis);
            if (free > 0 and flex_total > 0 and cp.flex > 0) {
                size += free * @as(f32, @floatFromInt(cp.flex)) / flex_total;
            } else if (free < 0 and shrink_weight > 0 and cp.shrink > 0) {
                size += free * @as(f32, @floatFromInt(cp.shrink)) * size / shrink_weight;
            }
            size = bound(cp, axis, @max(0, size));
            const cross = self.crossSize(handle, cp, axis.other(), cross_available, p.@"align");
            const cross_position = cross_start + alignOffset(p.@"align", cross_available - cross);
            const box: Box = if (axis == .horizontal)
                .{ .x = cursor, .y = cross_position, .width = size, .height = cross }
            else
                .{ .x = cross_position, .y = cursor, .width = cross, .height = size };
            self.place(handle, snap(box));
            cursor += size + spacing;
        }
    }

    /// A row/column child's size before flexing: explicit, else its content.
    /// A flexing child starts from nothing (just its minimum), so flexible
    /// siblings divide space by their weights alone.
    fn base(self: *Pass, handle: NodeHandle, p: *const properties.Stored, axis: Axis) f32 {
        if (explicit(p, axis)) |value| return bound(p, axis, value);
        if (p.flex > 0) return minimum(p, axis);
        return self.intrinsic(handle, axis);
    }
};

fn explicit(p: *const properties.Stored, axis: Axis) ?f32 {
    const value = if (axis == .horizontal) p.width else p.height;
    return if (value) |item| @floatFromInt(item) else null;
}

fn minimum(p: *const properties.Stored, axis: Axis) f32 {
    return @floatFromInt(if (axis == .horizontal) p.min_width else p.min_height);
}

fn bound(p: *const properties.Stored, axis: Axis, value: f32) f32 {
    const low = minimum(p, axis);
    const high: ?u32 = if (axis == .horizontal) p.max_width else p.max_height;
    var result = @max(low, value);
    if (high) |limit| result = @min(result, @max(low, @as(f32, @floatFromInt(limit))));
    return result;
}

fn alignOffset(alignment: properties.Align, free: f32) f32 {
    return switch (alignment) {
        .stretch, .start => 0,
        .center => @round(free / 2),
        .end => free,
    };
}

/// Whole-pixel edges, so fills and clips land crisply on the pixel grid.
fn snap(box: Box) Box {
    const left = @round(box.x);
    const top = @round(box.y);
    return .{
        .x = left,
        .y = top,
        .width = @max(0, @round(box.x + box.width) - left),
        .height = @max(0, @round(box.y + box.height) - top),
    };
}

/// Bring every node's box up to date for `viewport`. Does nothing when no
/// geometry input has changed since the last call.
pub fn update(scene: *Scene, viewport: Size, measurer: Measurer) void {
    if (!scene.layout_dirty and scene.layout_viewport[0] == viewport.width and
        scene.layout_viewport[1] == viewport.height) return;
    var pass = Pass{ .scene = scene, .measurer = measurer };
    const area = Box{ .width = viewport.width, .height = viewport.height };
    var root = scene.firstRoot();
    while (root) |handle| : (root = pass.node(handle).next_sibling) {
        if (!pass.node(handle).props().visible) continue;
        pass.place(handle, pass.overlay(handle, area, .stretch));
    }
    scene.layout_dirty = false;
    scene.layout_viewport = .{ viewport.width, viewport.height };
}

/// A node's box on the surface, including every offset applied to it and its
/// ancestors. Null for a stale handle or a node inside an invisible subtree.
pub fn bounds(scene: *const Scene, handle: NodeHandle) ?Box {
    const target = scene.get(handle) orelse return null;
    var box = Box{
        .x = target.layout.x,
        .y = target.layout.y,
        .width = target.layout.width,
        .height = target.layout.height,
    };
    var current: ?NodeHandle = handle;
    while (current) |item| {
        const value = scene.get(item) orelse return null;
        if (!value.props().visible) return null;
        box.x += value.props().offset_x;
        box.y += value.props().offset_y;
        current = value.parent;
    }
    return box;
}

const testing = std.testing;

const Fixture = struct {
    scene: Scene,
    mount: tree.MountContext,

    fn init(self: *Fixture) !void {
        self.scene = Scene.init(testing.allocator);
        self.mount = try self.scene.mount();
    }

    fn deinit(self: *Fixture) void {
        self.mount.deinit();
        self.scene.deinit();
    }

    fn add(self: *Fixture, kind: properties.NodeKind, parent: ?NodeHandle, values: []const properties.Value) !NodeHandle {
        const handle = try self.mount.create(kind, parent);
        for (values) |value| try self.scene.applyProperty(handle, value, if (value == .text) try testing.allocator.dupe(u8, value.text) else null);
        return handle;
    }

    fn box(self: *Fixture, handle: NodeHandle) Box {
        update(&self.scene, .{ .width = 200, .height = 40 }, Measurer.estimate);
        return bounds(&self.scene, handle).?;
    }
};

test "a row sizes children to their content, and invisible ones take no space" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const row = try f.add(.row, null, &.{ .{ .gap = 4 }, .{ .padding = .{ .left = 2 } } });
    const first = try f.add(.text, row, &.{ .{ .text = "ab" }, .{ .font_size = 10 } });
    const hidden = try f.add(.shape, row, &.{ .{ .width = 50 }, .{ .visible = false } });
    const second = try f.add(.shape, row, &.{.{ .width = 7 }});
    // "ab" at 10px estimates 11px wide.
    try testing.expectEqual(Box{ .x = 2, .y = 0, .width = 11, .height = 40 }, f.box(first));
    try testing.expectEqual(Box{ .x = 17, .y = 0, .width = 7, .height = 40 }, f.box(second));
    try testing.expect(bounds(&f.scene, hidden) == null);

    // Showing the hidden child pushes the next one along.
    try f.scene.applyProperty(hidden, .{ .visible = true }, null);
    try testing.expectEqual(@as(f32, 71), f.box(second).x);
}

test "flex shares leftover space by weight and justify places what is left" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const row = try f.add(.row, null, &.{});
    const fixed = try f.add(.shape, row, &.{.{ .width = 20 }});
    const one = try f.add(.spacer, row, &.{.{ .flex = 1 }});
    const three = try f.add(.spacer, row, &.{.{ .flex = 3 }});
    try testing.expectEqual(@as(f32, 45), f.box(one).width);
    try testing.expectEqual(@as(f32, 135), f.box(three).width);
    try testing.expectEqual(@as(f32, 65), f.box(three).x);
    _ = fixed;

    const centred = try f.add(.row, null, &.{.{ .justify = .center }});
    const middle = try f.add(.shape, centred, &.{.{ .width = 20 }});
    try testing.expectEqual(@as(f32, 90), f.box(middle).x);
    const spread = try f.add(.row, null, &.{.{ .justify = .between }});
    _ = try f.add(.shape, spread, &.{.{ .width = 20 }});
    const last = try f.add(.shape, spread, &.{.{ .width = 20 }});
    try testing.expectEqual(@as(f32, 180), f.box(last).x);
}

test "shrink takes overflow back from content-sized children, down to their minimum" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const row = try f.add(.row, null, &.{});
    const rigid = try f.add(.shape, row, &.{.{ .width = 120 }});
    const title = try f.add(.text, row, &.{ .{ .text = "a long window title here" }, .{ .font_size = 10 }, .{ .shrink = 1 }, .{ .min_width = 30 } });
    try testing.expectEqual(@as(f32, 80), f.box(title).width);
    try f.scene.applyProperty(rigid, .{ .width = 190 }, null);
    try testing.expectEqual(@as(f32, 30), f.box(title).width);
}

test "align places children across the axis; stretch fills it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const row = try f.add(.row, null, &.{.{ .@"align" = .center }});
    const icon = try f.add(.shape, row, &.{ .{ .width = 10 }, .{ .height = 10 } });
    try testing.expectEqual(Box{ .x = 0, .y = 15, .width = 10, .height = 10 }, f.box(icon));
    const label = try f.add(.text, row, &.{ .{ .text = "x" }, .{ .font_size = 12 } });
    try testing.expectEqual(@as(f32, 14), f.box(label).y);

    const stack = try f.add(.stack, null, &.{.{ .@"align" = .end }});
    const badge = try f.add(.shape, stack, &.{ .{ .width = 8 }, .{ .height = 8 } });
    try testing.expectEqual(Box{ .x = 192, .y = 32, .width = 8, .height = 8 }, f.box(badge));
}

test "offsets move a placed subtree without re-running layout" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const strip = try f.add(.row, null, &.{});
    const item = try f.add(.shape, strip, &.{.{ .width = 30 }});
    _ = f.box(item);
    try f.scene.applyProperty(strip, .{ .offset_x = -12 }, null);
    try testing.expect(!f.scene.layout_dirty);
    try testing.expectEqual(@as(f32, -12), bounds(&f.scene, item).?.x);
}

test "a changed text re-measures only its own path and moves later siblings" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const row = try f.add(.row, null, &.{});
    const clock = try f.add(.text, row, &.{ .{ .text = "9:59" }, .{ .font_size = 10 } });
    const after = try f.add(.shape, row, &.{.{ .width = 5 }});
    const before_x = f.box(after).x;
    try f.scene.applyProperty(clock, .{ .text = "10:00" }, try testing.allocator.dupe(u8, "10:00"));
    try testing.expect(f.scene.layout_dirty);
    try testing.expect(f.box(after).x > before_x);
    try testing.expect(!f.scene.layout_dirty);
}
