//! Ownership boundary for one retained Lua surface program.
//!
//! The descriptor supplies source; this object owns the VM, installed program,
//! and retained composition. Platform presenters only provide extents and
//! named service updates.

const std = @import("std");
const script = @import("whirlpool-script");
const lua_composition = @import("lua/composition.zig");

pub const Composition = struct {
    vm: script.program_loader.Vm,
    program: script.program_loader.Program,
    retained: lua_composition.Composition,

    /// `source` mounts the surface (see `script.config.SurfaceSpec.content`);
    /// it may `require` any of `modules`, which are borrowed for the
    /// composition's lifetime.
    pub fn init(allocator: std.mem.Allocator, modules: []const script.modules.Module, source: []const u8) !Composition {
        var vm = try script.program_loader.Vm.init(true);
        errdefer vm.deinit();
        // Surface programs are policy callbacks, not data providers. Removing
        // these libraries makes accidental file/process/timer I/O impossible
        // in the controller lane; application services must supply values.
        vm.removeGlobal("io");
        vm.removeGlobal("os");

        const loader = script.program_loader.Loader.init(allocator, .{});
        var program = try loader.loadShared("surface", &.{.{ .name = "surface", .source = source }}, modules);
        errdefer program.deinit();

        const retained = try lua_composition.Composition.mount(allocator, &vm, &program, .{});
        return .{ .vm = vm, .program = program, .retained = retained };
    }

    pub fn deinit(self: *Composition) void {
        self.retained.deinit();
        self.program.deinit();
        self.vm.deinit();
        self.* = undefined;
    }

    pub fn update(self: *Composition, update_value: script.program_loader.Update) !void {
        try self.retained.update(&self.vm, &self.program, update_value);
    }

    /// Whether anything has changed since the last frame was lowered.
    pub fn isDirty(self: *const Composition) bool {
        return self.retained.isDirty();
    }

    pub fn lower(
        self: *Composition,
        viewport: @import("skia_scene.zig").Viewport,
    ) !lua_composition.Frame {
        return self.retained.lower(viewport);
    }

    /// Measure text with the fonts of the renderer that will draw it.
    pub fn setTextMetrics(self: *Composition, metrics: @import("whirlpool-graphics").skia.TextMetrics) void {
        self.retained.setMeasurer(@import("skia_scene.zig").measurer(metrics));
    }
};

test "surface composition mounts retained Lua source" {
    var composition = try Composition.init(std.testing.allocator, testModules(),
        \\return function(root)
        \\  local label = root:text({ text = 'surface' })
        \\  return { update = function() label:set('text', 'updated') end }
        \\end
    );
    defer composition.deinit();

    var frame = try composition.lower(.{ .width = 100, .height = 20 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 2), frame.node_count);
}

test "surface composition cannot perform file or process I/O" {
    var composition = try Composition.init(std.testing.allocator, testModules(),
        \\assert(io == nil)
        \\assert(os == nil)
        \\return function(root)
        \\  root:text({ text = string.format("%s", "pure") })
        \\  return { update = function() end }
        \\end
    );
    defer composition.deinit();
}

test "surface controllers can retain nodes created during later updates" {
    var composition = try Composition.init(std.testing.allocator, testModules(),
        \\return function(root)
        \\  local child
        \\  return { update = function()
        \\    if not child then child = root:text({ text = 'late' }) end
        \\  end }
        \\end
    );
    defer composition.deinit();

    try composition.update(.{ .service = "grow", .values = &.{} });
    try composition.update(.{ .service = "grow", .values = &.{} });
    var frame = try composition.lower(.{ .width = 100, .height = 20 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 2), frame.node_count);
}

test "sample shell and decoration modules mount as distinct compositions" {
    var shell = try Composition.init(std.testing.allocator, testModules(),
        \\return require("lib.bar")
    );
    defer shell.deinit();
    var shell_frame = try shell.lower(.{ .width = 800, .height = 600 });
    defer shell_frame.deinit();
    try std.testing.expect(shell_frame.node_count > 100);
    var shell_background: ?@import("whirlpool-graphics").skia.Rect = null;
    var has_nonrectangular_polygon = false;
    for (shell_frame.drawList().ops) |operation| switch (operation) {
        .rect => |rect| if (rect.rect.width == 800 and rect.rect.height == 38) {
            shell_background = rect.rect;
        },
        .polygon => |polygon| {
            if (polygon.points.len == 4 and
                polygon.points.points[0].x > polygon.points.points[3].x and
                polygon.points.points[1].x > polygon.points.points[2].x)
            {
                has_nonrectangular_polygon = true;
            }
        },
        .text, .icon, .push_clip, .pop_clip => {},
    };
    const background = shell_background orelse return error.MissingShellBackground;
    try std.testing.expectEqual(@as(f32, 0), background.x);
    try std.testing.expectEqual(@as(f32, 562), background.y);
    try std.testing.expect(has_nonrectangular_polygon);

    const window_token = [_]script.program_loader.Value{
        .{ .string = "window" },
        .{ .string = "" },
        .{ .string = "foot" },
        .{ .string = "terminal" },
        .{ .boolean = true },
        .{ .number = 148 },
        .{ .string = "/icons/foot.svg" },
        .{ .string = "" },
        .{ .number = 0 },
        .{ .boolean = false },
    };
    const tokens = [_]script.program_loader.Value{.{ .array = &window_token }};
    try shell.update(.{
        .service = "desktop",
        .values = &.{
            .{ .number = 1 },
            .{ .array = &.{} },
            .{ .array = &tokens },
            .{ .number = 0 },
            .{ .number = 148 },
            .{ .number = 0 },
            .{ .number = 0 },
        },
    });
    var positioned = try shell.lower(.{ .width = 800, .height = 600 });
    defer positioned.deinit();
    var title_x: ?f32 = null;
    var icon_source: ?[]const u8 = null;
    for (positioned.drawList().ops) |operation| switch (operation) {
        .text => |text| if (std.mem.eql(u8, text.text, "terminal")) {
            title_x = text.x;
        },
        .icon => |icon| icon_source = icon.source,
        .rect, .polygon, .push_clip, .pop_clip => {},
    };
    const positioned_title = title_x orelse return error.MissingShellTitle;
    try std.testing.expect(positioned_title > 100 and positioned_title < 300);
    try std.testing.expectEqualStrings("/icons/foot.svg", icon_source orelse return error.MissingShellIcon);

    const second_window_token = [_]script.program_loader.Value{
        .{ .string = "window" },
        .{ .string = "" },
        .{ .string = "firefox" },
        .{ .string = "abcdefghijklm" },
        .{ .boolean = false },
        .{ .number = 148 },
        .{ .string = "/icons/firefox.svg" },
        .{ .string = "" },
        .{ .number = 152 },
        .{ .boolean = false },
    };
    const two_tokens = [_]script.program_loader.Value{
        .{ .array = &window_token },
        .{ .array = &second_window_token },
    };
    try shell.update(.{
        .service = "desktop",
        .values = &.{
            .{ .number = 1 },
            .{ .array = &.{} },
            .{ .array = &two_tokens },
            .{ .number = 0 },
            .{ .number = 300 },
            .{ .number = 0 },
            .{ .number = 0 },
        },
    });
    var two_windows = try shell.lower(.{ .width = 1200, .height = 600 });
    defer two_windows.deinit();
    var first_app_x: ?f32 = null;
    var second_app_x: ?f32 = null;
    var first_app_baseline: ?f32 = null;
    var first_title_baseline: ?f32 = null;
    for (two_windows.drawList().ops) |operation| switch (operation) {
        .text => |text| {
            if (std.mem.eql(u8, text.text, "foot")) {
                first_app_x = text.x;
                first_app_baseline = text.baseline;
            }
            if (std.mem.eql(u8, text.text, "terminal")) first_title_baseline = text.baseline;
            if (std.mem.eql(u8, text.text, "firefox")) second_app_x = text.x;
        },
        .rect, .polygon, .icon, .push_clip, .pop_clip => {},
    };
    try std.testing.expect((second_app_x orelse return error.MissingSecondShellWindow) >
        (first_app_x orelse return error.MissingFirstShellWindow));
    try std.testing.expect((first_title_baseline orelse return error.MissingFirstShellTitle) >
        (first_app_baseline orelse return error.MissingFirstShellAppId));

    const insertion_token = [_]script.program_loader.Value{
        .{ .string = "insertion" }, .{ .string = "" },    .{ .string = "" }, .{ .string = "" },
        .{ .boolean = false },      .{ .number = 3 },     .{ .string = "" }, .{ .string = "" },
        .{ .number = 148 },         .{ .boolean = true },
    };
    const marked_tokens = [_]script.program_loader.Value{
        .{ .array = &window_token },
        .{ .array = &insertion_token },
        .{ .array = &second_window_token },
    };
    try shell.update(.{
        .service = "desktop",
        .values = &.{
            .{ .number = 1 }, .{ .array = &.{} }, .{ .array = &marked_tokens },
            .{ .number = 0 }, .{ .number = 300 }, .{ .number = 0 },
            .{ .number = 0 },
        },
    });
    var with_marker = try shell.lower(.{ .width = 1200, .height = 600 });
    defer with_marker.deinit();
    var marked_second_x: ?f32 = null;
    for (with_marker.drawList().ops) |operation| switch (operation) {
        .text => |text| if (std.mem.eql(u8, text.text, "firefox")) {
            marked_second_x = text.x;
        },
        else => {},
    };
    try std.testing.expectEqual(second_app_x.?, marked_second_x orelse return error.MissingSecondShellWindow);

    var cpu_history = [_]script.program_loader.Value{.{ .number = 1 }} ** 24;
    var cpu_cores = [_]script.program_loader.Value{.{ .number = 0 }} ** 32;
    cpu_cores[0] = .{ .number = 100 };
    var rx_history = [_]script.program_loader.Value{.{ .number = 256 * 1024 }} ** 24;
    var tx_history = [_]script.program_loader.Value{.{ .number = 128 * 1024 }} ** 24;
    const cpu = [_]script.program_loader.Value{
        .{ .number = 0 }, .{ .number = 1 }, .{ .number = 32 }, .{ .array = &cpu_cores }, .{ .array = &cpu_history }, .{ .number = 1 },
    };
    const network = [_]script.program_loader.Value{
        .{ .number = 256 * 1024 }, .{ .number = 128 * 1024 }, .{ .array = &rx_history }, .{ .array = &tx_history }, .{ .number = 1 },
    };
    try shell.update(.{
        .service = "status",
        .values = &.{
            .{ .string = "12:34" },
            .{ .string = "Mon" },
            .{ .string = "2026-09-01" },
            .{ .array = &cpu },
            .{ .array = &network },
        },
    });
    try shell.update(.{ .service = "frame", .values = &.{.{ .number = 250 }} });
    var network_frame = try shell.lower(.{ .width = 1200, .height = 600 });
    defer network_frame.deinit();
    var rx_rises_from_center = false;
    var tx_falls_from_center = false;
    for (network_frame.drawList().ops) |operation| switch (operation) {
        .polygon => |polygon| {
            if (polygon.points.len <= 4) continue;
            var reaches_center = false;
            var rises = false;
            var falls = false;
            for (polygon.points.points[0..polygon.points.len]) |point| {
                reaches_center = reaches_center or @abs(point.y - 581) < 0.01;
                rises = rises or point.y < 580;
                falls = falls or point.y > 582;
            }
            rx_rises_from_center = rx_rises_from_center or (reaches_center and rises);
            tx_falls_from_center = tx_falls_from_center or (reaches_center and falls);
        },
        else => {},
    };
    try std.testing.expect(rx_rises_from_center);
    try std.testing.expect(tx_falls_from_center);

    var decoration = try Composition.init(std.testing.allocator, testModules(),
        \\return require("lib.decorator")
    );
    defer decoration.deinit();
    try decoration.update(.{
        .service = "decoration",
        .values = &.{ .{ .string = "Whirlpool" }, .{ .boolean = true } },
    });
    var frame = try decoration.lower(.{ .width = 800, .height = 28 });
    defer frame.deinit();
    try std.testing.expect(frame.node_count < 50);
    try std.testing.expectEqual(@as(usize, 2), frame.operationCount());
}

fn countPolygonsColored(composition: *Composition, rgb: [3]u8) !usize {
    var frame = try composition.lower(.{ .width = 800, .height = 600 });
    defer frame.deinit();
    var count: usize = 0;
    for (frame.drawList().ops) |operation| switch (operation) {
        .polygon => |polygon| {
            const color = polygon.color;
            const close = struct {
                fn eq(actual: f32, expected: u8) bool {
                    return @abs(actual * 255 - @as(f32, @floatFromInt(expected))) < 1;
                }
            };
            if (close.eq(color.r, rgb[0]) and close.eq(color.g, rgb[1]) and close.eq(color.b, rgb[2])) count += 1;
        },
        else => {},
    };
    return count;
}

test "the shell shows the active tag differently on an unfocused monitor" {
    const accent = [3]u8{ 0x89, 0xb4, 0xfa }; // theme.accent: monitor focused
    const overlay = [3]u8{ 0x45, 0x47, 0x5a }; // theme.overlay: active tag, monitor not focused
    const desktop = struct {
        fn values(focused: bool) [8]script.program_loader.Value {
            return .{
                .{ .number = 1 },
                .{ .array = &.{} },
                .{ .array = &.{} },
                .{ .number = 0 },
                .{ .number = 0 },
                .{ .number = 0 },
                .{ .number = 0 },
                .{ .boolean = focused },
            };
        }
    };

    var shell = try Composition.init(std.testing.allocator, testModules(),
        \\return require("lib.bar")
    );
    defer shell.deinit();

    const focused = desktop.values(true);
    try shell.update(.{ .service = "desktop", .values = &focused });
    const accent_focused = try countPolygonsColored(&shell, accent);
    const overlay_focused = try countPolygonsColored(&shell, overlay);

    const unfocused = desktop.values(false);
    try shell.update(.{ .service = "desktop", .values = &unfocused });
    const accent_unfocused = try countPolygonsColored(&shell, accent);
    const overlay_unfocused = try countPolygonsColored(&shell, overlay);

    // Exactly the active tag's cell changes colour.
    try std.testing.expectEqual(accent_focused - 1, accent_unfocused);
    try std.testing.expectEqual(overlay_focused + 1, overlay_unfocused);
}

// ---------------------------------------------------------------------------
// Bar layout: the angled design language.

const bar_width = 1500;
const bar_height = 38;
const slant = 0.30;

const Op = @import("whirlpool-graphics").skia.DrawOp;

fn colorNear(color: @import("whirlpool-graphics").skia.Color, rgb: [3]u8) bool {
    const close = struct {
        fn eq(actual: f32, expected: u8) bool {
            return @abs(actual * 255 - @as(f32, @floatFromInt(expected))) < 1;
        }
    };
    return close.eq(color.r, rgb[0]) and close.eq(color.g, rgb[1]) and close.eq(color.b, rgb[2]);
}

fn findText(ops: []const Op, text: []const u8) ?@FieldType(Op, "text") {
    for (ops) |operation| switch (operation) {
        .text => |item| if (std.mem.eql(u8, item.text, text)) return item,
        else => {},
    };
    return null;
}

/// First four-point polygon of the given colour (a panel outline).
fn findPanel(ops: []const Op, rgb: [3]u8) ?[4]@import("whirlpool-graphics").skia.Point {
    for (ops) |operation| switch (operation) {
        .polygon => |polygon| if (polygon.points.len == 4 and colorNear(polygon.color, rgb))
            return polygon.points.points[0..4].*,
        else => {},
    };
    return null;
}

/// Where the parallelogram's left edge is at a given height.
fn panelLeftAt(panel: [4]@import("whirlpool-graphics").skia.Point, y: f32) f32 {
    const t = (y - panel[0].y) / (panel[3].y - panel[0].y);
    return panel[0].x + (panel[3].x - panel[0].x) * t;
}

/// Where the parallelogram's horizontal middle is at a given height.
fn panelCenterAt(panel: [4]@import("whirlpool-graphics").skia.Point, y: f32) f32 {
    // Points run top-left, top-right, bottom-right, bottom-left.
    const t = (y - panel[0].y) / (panel[3].y - panel[0].y);
    const left = panel[0].x + (panel[3].x - panel[0].x) * t;
    const right = panel[1].x + (panel[2].x - panel[1].x) * t;
    return (left + right) / 2;
}

fn barShell(desktop_windows: []const script.program_loader.Value) !Composition {
    var shell = try Composition.init(std.testing.allocator, testModules(),
        \\return require("lib.bar")
    );
    errdefer shell.deinit();
    try shell.update(.{
        .service = "desktop",
        .values = &.{
            .{ .number = 2 },
            .{ .array = &.{} },
            .{ .array = desktop_windows },
            .{ .number = 0 },
            .{ .number = 400 },
            .{ .number = 0 },
            .{ .number = 0 },
            .{ .boolean = true },
        },
    });
    return shell;
}

test "text placed in a tag is centred in the slanted panel, without any per-glyph nudging" {
    var shell = try barShell(&.{});
    defer shell.deinit();
    var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
    defer frame.deinit();
    const ops = frame.drawList().ops;
    const panel = findPanel(ops, .{ 0x89, 0xb4, 0xfa }) orelse return error.MissingActiveTag;
    const label = findText(ops, "2") orelse return error.MissingTagLabel;

    try std.testing.expectEqual(@import("whirlpool-graphics").skia.TextAnchor.center, label.anchor);
    try std.testing.expectEqual(@import("whirlpool-graphics").skia.TextVertical.middle, label.vertical);
    const middle = (panel[0].y + panel[3].y) / 2;
    try std.testing.expectApproxEqAbs(panelCenterAt(panel, middle), label.x, 0.5);
    try std.testing.expectApproxEqAbs(middle, label.baseline, 0.5);
}

test "window indicators keep their icon and labels inside the slant with even margins" {
    const icon = "/icons/foot.svg";
    const window = [_]script.program_loader.Value{
        .{ .string = "window" }, .{ .string = "" },     .{ .string = "foot" }, .{ .string = "shell" },
        .{ .boolean = true },    .{ .number = 200 },    .{ .string = icon },   .{ .string = "" },
        .{ .number = 0 },        .{ .boolean = false },
    };
    const windows = [_]script.program_loader.Value{.{ .array = &window }};
    var shell = try barShell(&windows);
    defer shell.deinit();
    var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
    defer frame.deinit();
    const ops = frame.drawList().ops;

    var icon_rect: ?@import("whirlpool-graphics").skia.Rect = null;
    for (ops) |operation| switch (operation) {
        .icon => |item| icon_rect = item.rect,
        else => {},
    };
    const rect = icon_rect orelse return error.MissingWindowIcon;
    // Vertically centred in the bar.
    try std.testing.expectApproxEqAbs(@as(f32, bar_height) / 2, rect.y + rect.height / 2, 0.5);
    // theme.blend(accent, 112) over the bar background: the focused window's panel.
    const panel = findPanel(ops, .{ 77, 96, 136 }) orelse return error.MissingWindowPanel;
    // The icon clears the slanted left edge along its whole height: the margin
    // at its top (where the edge leans furthest in) is the body inset, and the
    // bottom corner is further out only by the slant's own travel.
    const margin_top = rect.x - panelLeftAt(panel, rect.y);
    const margin_bottom = rect.x - panelLeftAt(panel, rect.y + rect.height);
    try std.testing.expect(margin_top >= 8 and margin_top < 14);
    try std.testing.expectApproxEqAbs(slant * rect.height, margin_bottom - margin_top, 0.5);

    const app = findText(ops, "foot") orelse return error.MissingWindowLabel;
    const title = findText(ops, "shell") orelse return error.MissingWindowTitle;
    // Eight pixels between the icon and the label beside it.
    try std.testing.expectApproxEqAbs(rect.x + rect.width + 8, app.x, 0.5);
    try std.testing.expectApproxEqAbs(app.x, title.x, 0.01);
    // The two lines straddle the bar's middle.
    try std.testing.expect(app.baseline < @as(f32, bar_height) / 2 and title.baseline > @as(f32, bar_height) / 2 - 1);
}

test "level bars are flush with the panel's slanted edge" {
    var shell = try barShell(&.{});
    defer shell.deinit();
    try shell.update(.{ .service = "frame", .values = &.{.{ .number = 0 }} });
    const audio = [_]script.program_loader.Value{ .{ .number = 63 }, .{ .boolean = false }, .{ .boolean = false } };
    try shell.update(.{
        .service = "status",
        .values = &.{
            .{ .string = "12:34" }, .{ .string = "Mon" }, .{ .string = "2026-09-01" },
            .{ .array = &.{} },     .{ .array = &.{} },   .{ .array = &audio },
        },
    });
    var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
    defer frame.deinit();
    const ops = frame.drawList().ops;
    // The purple level fill and the purple panel it sits in.
    const purple = [3]u8{ 0xcb, 0xa6, 0xf7 };
    // theme.blend(purple) over the bar background: 100/255 of purple.
    const panel_color = [3]u8{ 98, 83, 125 };
    var fill: ?[4]@import("whirlpool-graphics").skia.Point = null;
    for (ops) |operation| switch (operation) {
        .polygon => |polygon| if (fill == null and polygon.points.len == 4 and colorNear(polygon.color, purple) and polygon.color.a > 0.9) {
            fill = polygon.points.points[0..4].*;
        },
        else => {},
    };
    const level = fill orelse return error.MissingLevelFill;
    // Bottom-left of the fill is the panel's bottom-left; its left edge leans
    // by the panel slant, and the fill's height is the level.
    const panel = findPanel(ops, panel_color) orelse return error.MissingAudioPanel;
    const rise = level[3].y - level[0].y;
    // Both left vertices of the fill lie on the panel's own left edge.
    for ([_]usize{ 0, 3 }) |index| {
        const t = (level[index].y - panel[0].y) / (panel[3].y - panel[0].y);
        const edge = panel[0].x + (panel[3].x - panel[0].x) * t;
        try std.testing.expectApproxEqAbs(edge, level[index].x, 0.5);
    }
    try std.testing.expectApproxEqAbs(@as(f32, bar_height) * 0.63, rise, 1.5);
    try std.testing.expectApproxEqAbs(slant, (level[0].x - level[3].x) / rise, 0.01);
}

const Feed = struct {
    shell: Composition,
    history: [24]script.program_loader.Value,
    sequence: f64 = 0,

    fn init() !Feed {
        return .{ .shell = try barShell(&.{}), .history = [_]script.program_loader.Value{.{ .number = 0 }} ** 24 };
    }

    fn deinit(self: *Feed) void {
        self.shell.deinit();
    }

    /// One 500ms status sample at time `at_ms` with network receive rate `rate`.
    fn sample(self: *Feed, at_ms: f64, rate: f64) !void {
        self.sequence += 1;
        for (&self.history) |*value| value.* = .{ .number = rate };
        const network = [_]script.program_loader.Value{
            .{ .number = rate }, .{ .number = 0 }, .{ .array = &self.history }, .{ .array = &self.history }, .{ .number = self.sequence },
        };
        try self.shell.update(.{ .service = "frame", .values = &.{.{ .number = at_ms }} });
        try self.shell.update(.{
            .service = "status",
            .values = &.{
                .{ .string = "12:34" }, .{ .string = "Mon" },   .{ .string = "2026-09-01" },
                .{ .array = &.{} },     .{ .array = &network },
            },
        });
    }

    fn frame(self: *Feed, at_ms: f64) !void {
        try self.shell.update(.{ .service = "frame", .values = &.{.{ .number = at_ms }} });
    }

    /// How intense the receive heat cells are, 0..1: how far their colour has
    /// moved from the panel colour towards the receive colour (judged by red).
    fn receiveLevel(self: *Feed) !f32 {
        var frame_value = try self.shell.lower(.{ .width = bar_width, .height = bar_height });
        defer frame_value.deinit();
        const panel_red: f32 = (148.0 * 100.0 + 30.0 * 155.0) / 255.0;
        const fill_red: f32 = (166.0 * 220.0 + 30.0 * 35.0) / 255.0;
        const half: f32 = bar_height / 2;
        var level: f32 = 0;
        for (frame_value.drawList().ops) |operation| switch (operation) {
            .polygon => |polygon| {
                if (polygon.points.len != 4 or polygon.color.a < 0.99) continue;
                // Heat cells span their whole half of the bar, the top half here.
                var top: f32 = bar_height;
                var bottom: f32 = 0;
                for (polygon.points.points[0..4]) |point| {
                    top = @min(top, point.y);
                    bottom = @max(bottom, point.y);
                }
                if (bottom > half + 0.5 or bottom - top < half - 0.01) continue;
                const red = polygon.color.r * 255;
                if (red < panel_red - 1 or red > fill_red + 1) continue;
                level = @max(level, (red - panel_red) / (fill_red - panel_red));
            },
            else => {},
        };
        return level;
    }

    fn text(self: *Feed, wanted: []const u8) !bool {
        var frame_value = try self.shell.lower(.{ .width = bar_width, .height = bar_height });
        defer frame_value.deinit();
        return findText(frame_value.drawList().ops, wanted) != null;
    }
};

test "the network chart's scale follows the data smoothly" {
    var feed = try Feed.init();
    defer feed.deinit();
    // Sustained 10 MB/s: after settling, the cells are nearly at full intensity.
    var time: f64 = 0;
    while (time <= 8000) : (time += 500) try feed.sample(time, 10_000_000);
    const settled = try feed.receiveLevel();
    try std.testing.expect(settled > 0.85 and settled < 1.0);

    // Traffic drops to a tenth. The ceiling must not snap down: the cells dim
    // at first, then slowly brighten as the scale follows the data.
    time += 500;
    try feed.sample(time, 1_000_000);
    time += 250;
    try feed.frame(time);
    const just_after = try feed.receiveLevel();
    try std.testing.expect(just_after < 0.45);
    const stop = time + 12_000;
    while (time <= stop) : (time += 500) try feed.sample(time, 1_000_000);
    const adapted = try feed.receiveLevel();
    try std.testing.expect(adapted > 0.75);
    // ...and it grew gradually rather than in one step.
    var midway_feed = try Feed.init();
    defer midway_feed.deinit();
    var t: f64 = 0;
    while (t <= 8000) : (t += 500) try midway_feed.sample(t, 10_000_000);
    t += 500;
    try midway_feed.sample(t, 1_000_000);
    const midpoint = t + 2000;
    while (t <= midpoint) : (t += 500) try midway_feed.sample(t, 1_000_000);
    const partway = try midway_feed.receiveLevel();
    try std.testing.expect(partway > just_after and partway < adapted);
}

test "slow traffic stays dim, and a burst is fitted within a sample interval" {
    var feed = try Feed.init();
    defer feed.deinit();
    var time: f64 = 0;
    while (time <= 6000) : (time += 500) try feed.sample(time, 20_000);
    // Below the zoom floor the chart does not magnify quiet traffic.
    const idle = try feed.receiveLevel();
    try std.testing.expect(idle > 0.05 and idle < 0.25);
    // 175 MB/s (a gigabit and change) arrives. It stays offscreen for a sample
    // interval, and by then the scale has risen to (nearly) fit it, and it
    // settles just under the top of the range rather than being clipped.
    time += 500;
    try feed.sample(time, 175_000_000);
    time += 500;
    try feed.frame(time);
    try std.testing.expect(try feed.receiveLevel() > 0.85);
    time += 500;
    try feed.frame(time);
    const burst = try feed.receiveLevel();
    try std.testing.expect(burst > 0.85 and burst < 1.0);
}

fn slantOf(top: @import("whirlpool-graphics").skia.Point, bottom: @import("whirlpool-graphics").skia.Point) f32 {
    return (top.x - bottom.x) / (bottom.y - top.y);
}

test "memory shows programs, ZFS ARC and cache as stacked bands, plus swap" {
    var shell = try barShell(&.{});
    defer shell.deinit();
    const memory = [_]script.program_loader.Value{
        .{ .number = 100 }, .{ .number = 40 },   .{ .number = 30 },  .{ .number = 10 },
        .{ .number = 20 },  .{ .number = 1000 }, .{ .number = 250 },
    };
    try shell.update(.{
        .service = "status",
        .values = &.{
            .{ .string = "12:34" }, .{ .string = "Mon" }, .{ .string = "2026-09-01" }, .{ .array = &.{} },
            .{ .array = &.{} },     .{ .array = &.{} },   .{ .array = &memory },
        },
    });
    var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
    defer frame.deinit();
    const ops = frame.drawList().ops;

    // theme.green / theme.cyan / theme.orange bands, as heights of their polygons.
    const Band = struct { rgb: [3]u8, alpha_min: f32, alpha_max: f32, expected_rows: f32 };
    const bands = [_]Band{
        .{ .rgb = .{ 166, 227, 161 }, .alpha_min = 0.9, .alpha_max = 1.01, .expected_rows = 15 }, // used 40%
        .{ .rgb = .{ 148, 226, 213 }, .alpha_min = 0.9, .alpha_max = 1.01, .expected_rows = 4 }, // arc 10%
        .{ .rgb = .{ 166, 227, 161 }, .alpha_min = 0.4, .alpha_max = 0.5, .expected_rows = 11 }, // cache 30%
        .{ .rgb = .{ 250, 179, 135 }, .alpha_min = 0.9, .alpha_max = 1.01, .expected_rows = 10 }, // swap 25%
    };
    var tops: [4]f32 = undefined;
    for (bands, 0..) |band, index| {
        var found = false;
        for (ops) |operation| switch (operation) {
            .polygon => |polygon| if (polygon.points.len == 4 and colorNear(polygon.color, band.rgb) and
                polygon.color.a > band.alpha_min and polygon.color.a < band.alpha_max)
            {
                const rows = polygon.points.points[3].y - polygon.points.points[0].y;
                if (@abs(rows - band.expected_rows) < 0.6) {
                    found = true;
                    tops[index] = polygon.points.points[0].y;
                }
            },
            else => {},
        };
        try std.testing.expect(found);
    }
    // The stack is contiguous: each band starts where the one below ends.
    try std.testing.expectApproxEqAbs(@as(f32, bar_height) - 15, tops[0], 0.6);
    try std.testing.expectApproxEqAbs(tops[0] - 4, tops[1], 0.6);
    try std.testing.expectApproxEqAbs(tops[1] - 11, tops[2], 0.6);
}

test "throughput readouts keep unit and digit positions fixed as values change" {
    // Network rates arrive in bytes per second and read in bits per second.
    const Case = struct { bytes: f64, number: []const u8, unit: []const u8 };
    const cases = [_]Case{
        .{ .bytes = 0, .number = "0", .unit = "b/s" },
        .{ .bytes = 12_500, .number = "100", .unit = "kb/s" },
        .{ .bytes = 1_250_000, .number = "10", .unit = "Mb/s" },
        .{ .bytes = 17_500_000, .number = "140", .unit = "Mb/s" },
        .{ .bytes = 175_000_000, .number = "1.4", .unit = "Gb/s" },
        // Rounds up across the unit boundary instead of reading "1000kb/s".
        .{ .bytes = 124_960, .number = "1.0", .unit = "Mb/s" },
    };
    var right_edge: ?f32 = null;
    var unit_left: ?f32 = null;
    for (cases) |case| {
        var feed = try Feed.init();
        defer feed.deinit();
        try feed.sample(0, case.bytes);
        var frame_value = try feed.shell.lower(.{ .width = bar_width, .height = bar_height });
        defer frame_value.deinit();
        const ops = frame_value.drawList().ops;
        const number = findText(ops, case.number) orelse return error.MissingNumber;
        const unit = findText(ops, case.unit) orelse return error.MissingUnit;
        try std.testing.expectEqual(@import("whirlpool-graphics").skia.TextAnchor.end, number.anchor);
        if (right_edge) |edge| try std.testing.expectEqual(edge, number.x) else right_edge = number.x;
        if (unit_left) |edge| try std.testing.expectEqual(edge, unit.x) else unit_left = unit.x;
    }
}

test "the readout holds still through small changes and once-a-second refreshes" {
    var feed = try Feed.init();
    defer feed.deinit();
    // 5 MB/s is 40 Mb/s.
    try feed.sample(0, 5_000_000);
    try std.testing.expect(try feed.text("40"));
    // Within 10% of what is shown: unchanged however often it is sampled.
    try feed.sample(1500, 5_200_000);
    try feed.sample(3000, 4_800_000);
    try std.testing.expect(try feed.text("40"));
    // A real change is picked up, but not before a second has passed.
    try feed.sample(3500, 10_000_000);
    try std.testing.expect(try feed.text("40"));
    try feed.sample(4600, 10_000_000);
    try std.testing.expect(try feed.text("80"));
}

test "sparklines and core cells lean with the panel instead of being rectangular" {
    var shell = try barShell(&.{});
    defer shell.deinit();
    var history = [_]script.program_loader.Value{.{ .number = 4 }} ** 24;
    var cores = [_]script.program_loader.Value{.{ .number = 100 }} ** 32;
    const cpu = [_]script.program_loader.Value{
        .{ .number = 90 }, .{ .number = 8 }, .{ .number = 32 }, .{ .array = &cores }, .{ .array = &history }, .{ .number = 1 },
    };
    try shell.update(.{
        .service = "status",
        .values = &.{
            .{ .string = "12:34" }, .{ .string = "Mon" }, .{ .string = "2026-09-01" }, .{ .array = &cpu },
        },
    });
    try shell.update(.{ .service = "frame", .values = &.{.{ .number = 200 }} });
    var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
    defer frame.deinit();

    // The main CPU plot sits immediately left of the core heat cells.
    var cell_x: f32 = std.math.inf(f32);
    for (frame.drawList().ops) |operation| switch (operation) {
        .polygon => |polygon| if (polygon.points.len == 4 and colorNear(polygon.color, .{ 249, 226, 175 })) {
            cell_x = @min(cell_x, polygon.points.points[0].x);
        },
        else => {},
    };
    // Copied out: a slice into the loop's by-value capture would dangle.
    var last_plot: ?@import("whirlpool-graphics").skia.Polygon = null;
    var cells: usize = 0;
    for (frame.drawList().ops) |operation| switch (operation) {
        .polygon => |polygon| {
            const points = polygon.points.points[0..polygon.points.len];
            // Plot outlines are many-vertex yellow polygons: baseline, curve..., baseline.
            if (points.len > 4 and colorNear(polygon.color, .{ 219, 199, 157 }) and points[0].x < cell_x and points[0].x > cell_x - 140)
                last_plot = polygon.points;
            // Core heat cells are small yellow parallelograms, not rectangles.
            if (points.len == 4 and colorNear(polygon.color, .{ 249, 226, 175 }) and polygon.color.a < 1.01) {
                const height = points[3].y - points[0].y;
                if (height > 6 and height < 10) {
                    cells += 1;
                    try std.testing.expectApproxEqAbs(slant, slantOf(points[0], points[3]), 0.02);
                    try std.testing.expectApproxEqAbs(slant, slantOf(points[1], points[2]), 0.02);
                }
            }
        },
        else => {},
    };
    // The plot's two ends are slanted edges, parallel to the panel's.
    const found = last_plot orelse return error.MissingPlot;
    const plot = found.points[0..found.len];
    try std.testing.expectApproxEqAbs(slant, slantOf(plot[1], plot[0]), 0.02);
    try std.testing.expectApproxEqAbs(slant, slantOf(plot[plot.len - 2], plot[plot.len - 1]), 0.02);
    try std.testing.expectEqual(@as(usize, 16), cells);
}

test "each reported filesystem is a chip with its own bar, name, free space and I/O" {
    var shell = try barShell(&.{});
    defer shell.deinit();
    const gib = 1024.0 * 1024.0 * 1024.0;
    const root_fs = [_]script.program_loader.Value{
        .{ .string = "/" },               .{ .number = 1000 * gib }, .{ .number = 600 * gib }, .{ .number = 400 * gib },
        .{ .number = 120 * 1024 * 1024 }, .{ .number = 2048 },
    };
    const pool = [_]script.program_loader.Value{
        .{ .string = "tank" }, .{ .number = 7000 * gib }, .{ .number = 4000 * gib }, .{ .number = 3000 * gib },
        .{ .number = 0 },      .{ .number = 0 },
    };
    // More filesystems than the old single column could show, one of them a
    // pool with nothing mounted.
    const unmounted = [_]script.program_loader.Value{
        .{ .string = "bulk" }, .{ .number = 2000 * gib }, .{ .number = 500 * gib }, .{ .number = 1500 * gib },
        .{ .number = 0 },      .{ .number = 0 },
    };
    const fourth = [_]script.program_loader.Value{
        .{ .string = "backup" }, .{ .number = 500 * gib }, .{ .number = 450 * gib }, .{ .number = 50 * gib },
        .{ .number = 0 },        .{ .number = 0 },
    };
    const disks = [_]script.program_loader.Value{
        .{ .array = &root_fs }, .{ .array = &pool }, .{ .array = &unmounted }, .{ .array = &fourth },
    };
    try shell.update(.{
        .service = "status",
        .values = &.{
            .{ .string = "12:34" }, .{ .string = "Mon" }, .{ .string = "2026-09-01" }, .{ .array = &.{} },
            .{ .array = &.{} },     .{ .array = &.{} },   .{ .array = &.{} },          .{ .array = &disks },
        },
    });
    var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
    defer frame.deinit();
    const ops = frame.drawList().ops;

    const names = [_][]const u8{ "/", "tank", "bulk", "backup" };
    const frees = [_][]const u8{ "400G", "2.93T", "1.46T", "50.0G" };
    var previous_x: f32 = -1;
    for (names, frees) |name, free| {
        const name_text = findText(ops, name) orelse return error.MissingChipName;
        const free_text = findText(ops, free) orelse return error.MissingChipFree;
        // Name left-aligned, free space right-aligned, on one line; chips run left to right.
        try std.testing.expectEqual(@import("whirlpool-graphics").skia.TextAnchor.start, name_text.anchor);
        try std.testing.expectEqual(@import("whirlpool-graphics").skia.TextAnchor.end, free_text.anchor);
        try std.testing.expectEqual(name_text.baseline, free_text.baseline);
        try std.testing.expect(name_text.x > previous_x);
        try std.testing.expect(free_text.x > name_text.x);
        previous_x = free_text.x;
    }
    // The root filesystem's throughput: number and unit in one right-aligned slot.
    try std.testing.expect(findText(ops, "120M") != null);
    try std.testing.expect(findText(ops, "2.0K") != null);
}

test "memory says what its numbers are out of, and swap is quiet until used" {
    const gib = 1024.0 * 1024.0 * 1024.0;
    const Case = struct { swap_used: f64, expect_dim: bool };
    for ([_]Case{ .{ .swap_used = 0, .expect_dim = true }, .{ .swap_used = 60 * gib, .expect_dim = false } }) |case| {
        var shell = try barShell(&.{});
        defer shell.deinit();
        const memory = [_]script.program_loader.Value{
            .{ .number = 126 * gib }, .{ .number = 10.9 * gib }, .{ .number = 30 * gib },       .{ .number = 12 * gib },
            .{ .number = 70 * gib },  .{ .number = 160 * gib },  .{ .number = case.swap_used }, .{ .number = 3 * gib },
            .{ .number = 1 * gib },
        };
        try shell.update(.{
            .service = "status",
            .values = &.{
                .{ .string = "12:34" }, .{ .string = "Mon" }, .{ .string = "2026-09-01" }, .{ .array = &.{} },
                .{ .array = &.{} },     .{ .array = &.{} },   .{ .array = &memory },
            },
        });
        var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
        defer frame.deinit();
        const ops = frame.drawList().ops;
        // "used/total", in the total's unit.
        try std.testing.expect(findText(ops, "10.9/126G") != null);
        try std.testing.expect(findText(ops, "42.0G cache") != null);
        // Swap: used out of its total; zswap noted subtly on the caption line.
        const ratio = if (case.expect_dim) "0.00/160G" else "60.0/160G";
        const swap = findText(ops, ratio) orelse return error.MissingSwapRatio;
        try std.testing.expect(findText(ops, "swap · zs 3.00G") != null);
        // Unused swap is dim text, not an alarm colour.
        const is_dim = swap.color.a < 0.7 and swap.color.r > 0.7;
        try std.testing.expectEqual(case.expect_dim, is_dim);
    }
}

test "adjacent panels tuck under their neighbour so no seam shows between them" {
    var shell = try barShell(&.{});
    defer shell.deinit();
    var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
    defer frame.deinit();
    // Section backgrounds are the tall four-point polygons. Consecutive ones in
    // the right-hand group must overlap along the shared diagonal.
    var previous: ?[4]@import("whirlpool-graphics").skia.Point = null;
    var checked: usize = 0;
    for (frame.drawList().ops) |operation| switch (operation) {
        .polygon => |polygon| if (polygon.points.len == 4 and polygon.color.a > 0.99) {
            const points = polygon.points.points[0..4].*;
            const height = points[3].y - points[0].y;
            const wide = points[2].x - points[3].x > 40;
            if (height > 37 and wide) {
                if (previous) |before| {
                    // Right edge of the earlier panel reaches past the left edge of this one.
                    const gap = points[3].x - before[2].x;
                    if (@abs(gap) < 3) {
                        try std.testing.expect(gap <= -1.0);
                        checked += 1;
                    }
                }
                previous = points;
            }
        },
        else => {},
    };
    try std.testing.expect(checked >= 3);
}

test "every history style stays inside its slanted cell and draws its samples" {
    var shell = try barShell(&.{});
    defer shell.deinit();
    var history = [_]script.program_loader.Value{.{ .number = 4 }} ** 24;
    var cores = [_]script.program_loader.Value{.{ .number = 50 }} ** 8;
    const cpu = [_]script.program_loader.Value{
        .{ .number = 40 }, .{ .number = 4 }, .{ .number = 8 }, .{ .array = &cores }, .{ .array = &history }, .{ .number = 1 },
    };
    try shell.update(.{
        .service = "status",
        .values = &.{
            .{ .string = "12:34" }, .{ .string = "Mon" }, .{ .string = "2026-09-01" }, .{ .array = &cpu },
        },
    });
    try shell.update(.{ .service = "frame", .values = &.{.{ .number = 100 }} });
    var frame = try shell.lower(.{ .width = bar_width, .height = bar_height });
    defer frame.deinit();
    // The showcase has one plot per style: columns and ticks draw one narrow
    // polygon per sample (small 4-point polygons of the plot colour), the rest
    // draw few larger outlines.
    var small_plot_polygons: usize = 0;
    for (frame.drawList().ops) |operation| switch (operation) {
        .polygon => |polygon| if (polygon.points.len == 4 and colorNear(polygon.color, .{ 219, 199, 157 })) {
            const width = polygon.points.points[1].x - polygon.points.points[0].x;
            if (width < 4) small_plot_polygons += 1;
        },
        else => {},
    };
    // columns + ticks, each with a bar per visible sample.
    try std.testing.expect(small_plot_polygons >= 2 * 20);
}

/// The example configuration's modules, shared by every test here (and so
/// allocated once, outside the leak-checked testing allocator).
var test_modules_cache: ?script.modules.Set = null;
fn testModules() []const script.modules.Module {
    if (test_modules_cache == null)
        test_modules_cache = script.modules.collect(std.heap.page_allocator, std.testing.io, "config") catch @panic("example configuration modules");
    return test_modules_cache.?.modules;
}
