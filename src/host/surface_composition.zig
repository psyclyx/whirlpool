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

test "sample shell and decoration modules mount as distinct compositions" {
    var shell = try Composition.init(std.testing.allocator,
        \\return require("whirlpool.shell")
    );
    defer shell.deinit();
    var shell_frame = try shell.snapshotAndLower(.{ .width = 800, .height = 600 });
    defer shell_frame.deinit();
    try std.testing.expect(shell_frame.node_count > 100);
    var shell_background: ?@import("whirlpool-graphics").skia.Rect = null;
    for (shell_frame.drawList().ops) |operation| switch (operation) {
        .rect => |rect| if (rect.rect.width == 800 and rect.rect.height == 38) {
            shell_background = rect.rect;
            break;
        },
        .text => {},
    };
    const background = shell_background orelse return error.MissingShellBackground;
    try std.testing.expectEqual(@as(f32, 0), background.x);
    try std.testing.expectEqual(@as(f32, 562), background.y);

    try shell.update(.{
        .service = "desktop",
        .values = &.{
            .{ .number = 1 },
            .{ .array = &.{} },
            .{ .boolean = true },
            .{ .string = "foot" },
            .{ .string = "terminal" },
            .{ .array = &.{} },
        },
    });
    var positioned = try shell.snapshotAndLower(.{ .width = 800, .height = 600 });
    defer positioned.deinit();
    var title_x: ?f32 = null;
    for (positioned.drawList().ops) |operation| switch (operation) {
        .text => |text| if (std.mem.eql(u8, text.text, "terminal")) {
            title_x = text.x;
            break;
        },
        .rect => {},
    };
    try std.testing.expect((title_x orelse return error.MissingShellTitle) > 350);

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
