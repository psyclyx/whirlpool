//! Ownership boundary for one retained Lua surface program.
//!
//! The descriptor supplies source; this object owns the VM, installed program,
//! and retained composition. Platform presenters only provide extents and
//! named service updates.

const std = @import("std");
const script = @import("whirlpool-script");
const lua_stdlib = @import("whirlpool-lua-stdlib");
const lua_composition = @import("lua/composition.zig");

pub const Composition = struct {
    vm: script.program_loader.Vm,
    program: script.program_loader.Program,
    retained: lua_composition.Composition,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Composition {
        var vm = try script.program_loader.Vm.init(true);
        errdefer vm.deinit();
        // Surface programs are policy callbacks, not data providers. Removing
        // these libraries makes accidental file/process/timer I/O impossible
        // in the controller lane; application services must supply values.
        vm.removeGlobal("io");
        vm.removeGlobal("os");

        const loader = script.program_loader.Loader.init(allocator, .{});
        const modules = [_]script.program_loader.Module{
            .{ .name = "surface", .source = source },
            .{ .name = "whirlpool.workspace", .source = lua_stdlib.workspace },
            .{ .name = "whirlpool.theme", .source = lua_stdlib.theme },
            .{ .name = "whirlpool.status", .source = lua_stdlib.status },
            .{ .name = "whirlpool.shell", .source = lua_stdlib.shell },
            .{ .name = "whirlpool.decorator", .source = lua_stdlib.decorator },
        };
        var program = try loader.load("surface", &modules);
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

    pub fn snapshotAndLower(
        self: *Composition,
        viewport: @import("skia_scene.zig").Viewport,
    ) !lua_composition.Frame {
        return self.retained.snapshotAndLower(viewport);
    }
};

test "surface composition mounts retained Lua source" {
    var composition = try Composition.init(std.testing.allocator,
        \\return function(root)
        \\  local label = root:text({ text = 'surface' })
        \\  return { update = function() label:set('text', 'updated') end }
        \\end
    );
    defer composition.deinit();

    var frame = try composition.snapshotAndLower(.{ .width = 100, .height = 20 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 2), frame.node_count);
}

test "surface composition cannot perform file or process I/O" {
    var composition = try Composition.init(std.testing.allocator,
        \\assert(io == nil)
        \\assert(os == nil)
        \\return function(root)
        \\  root:text({ text = string.format("%s", "pure") })
        \\  return { update = function() end }
        \\end
    );
    defer composition.deinit();
}

test "surface composition exposes the workspace stdlib module" {
    var composition = try Composition.init(std.testing.allocator,
        \\return function(root)
        \\  local Workspace = require('whirlpool.workspace')
        \\  local workspaces = Workspace.new({ count = 3 })
        \\  local label = root:text({ text = table.concat(workspaces:labels(), ' ') })
        \\  return { update = function(_, service, values)
        \\    if workspaces:update(service, values) then
        \\      label:set('text', table.concat(workspaces:labels(), ' '))
        \\    end
        \\  end }
        \\end
    );
    defer composition.deinit();

    try composition.update(.{ .service = "workspaces", .values = &.{.{ .number = 2 }} });
    var frame = try composition.snapshotAndLower(.{ .width = 100, .height = 20 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 2), frame.node_count);
}

test "surface controllers can retain nodes created during later updates" {
    var composition = try Composition.init(std.testing.allocator,
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
    var frame = try composition.snapshotAndLower(.{ .width = 100, .height = 20 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(usize, 2), frame.node_count);
}

test "sample shell and decoration modules mount as distinct compositions" {
    var shell = try Composition.init(std.testing.allocator,
        \\return require("whirlpool.shell")
    );
    defer shell.deinit();
    var shell_frame = try shell.snapshotAndLower(.{ .width = 800, .height = 600 });
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
    var positioned = try shell.snapshotAndLower(.{ .width = 800, .height = 600 });
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
    var two_windows = try shell.snapshotAndLower(.{ .width = 1200, .height = 600 });
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
    var with_marker = try shell.snapshotAndLower(.{ .width = 1200, .height = 600 });
    defer with_marker.deinit();
    var marked_second_x: ?f32 = null;
    for (with_marker.drawList().ops) |operation| switch (operation) {
        .text => |text| if (std.mem.eql(u8, text.text, "firefox")) {
            marked_second_x = text.x;
        },
        else => {},
    };
    try std.testing.expectEqual(second_app_x.?, marked_second_x orelse return error.MissingSecondShellWindow);

    var cpu_history = [_]script.program_loader.Value{.{ .number = 0 }} ** 15;
    var rx_history = [_]script.program_loader.Value{.{ .number = 256 * 1024 }} ** 16;
    var tx_history = [_]script.program_loader.Value{.{ .number = 128 * 1024 }} ** 16;
    _ = &cpu_history;
    _ = &rx_history;
    _ = &tx_history;
    try shell.update(.{
        .service = "status",
        .values = &.{
            .{ .string = "12:34" },    .{ .string = "Mon" },       .{ .string = "2026-09-01" },
            .{ .number = 0 },          .{ .array = &cpu_history }, .{ .number = 0 },
            .{ .number = 0 },          .{ .number = 256 * 1024 },  .{ .number = 128 * 1024 },
            .{ .array = &rx_history }, .{ .array = &tx_history },  .{ .number = 0 },
            .{ .boolean = false },     .{ .boolean = false },      .{ .boolean = false },
            .{ .number = 0 },          .{ .boolean = false },      .{ .number = 1 },
        },
    });
    try shell.update(.{ .service = "frame", .values = &.{.{ .number = 250 }} });
    var network_frame = try shell.snapshotAndLower(.{ .width = 1200, .height = 600 });
    defer network_frame.deinit();
    var rx_reaches_center = false;
    var tx_starts_at_center = false;
    for (network_frame.drawList().ops) |operation| switch (operation) {
        .polygon => |polygon| {
            if (polygon.points.len != 4) continue;
            const points = polygon.points.points;
            const width = points[2].x - points[3].x;
            if (@abs(width - 2) > 0.01) continue;
            if (polygon.color.g > 0.88 and polygon.color.r > 0.64 and polygon.color.r < 0.67)
                rx_reaches_center = @abs(points[2].y - 581) < 0.01;
            if (polygon.color.g > 0.88 and polygon.color.r > 0.57 and polygon.color.r < 0.60)
                tx_starts_at_center = @abs(points[0].y - 581) < 0.01;
        },
        else => {},
    };
    try std.testing.expect(rx_reaches_center);
    try std.testing.expect(tx_starts_at_center);

    var decoration = try Composition.init(std.testing.allocator,
        \\return require("whirlpool.decorator")
    );
    defer decoration.deinit();
    try decoration.update(.{
        .service = "decoration",
        .values = &.{ .{ .string = "Whirlpool" }, .{ .boolean = true } },
    });
    var frame = try decoration.snapshotAndLower(.{ .width = 800, .height = 28 });
    defer frame.deinit();
    try std.testing.expect(frame.node_count < 50);
    try std.testing.expectEqual(@as(usize, 2), frame.operationCount());
}
