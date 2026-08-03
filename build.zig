const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const model = b.addModule("whirlpool-model", .{
        .root_source_file = b.path("src/model/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shell = b.addModule("whirlpool-shell", .{
        .root_source_file = b.path("src/shell/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "whirlpool-model", .module = model }},
    });
    const runtime = b.addModule("whirlpool-runtime", .{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const river = b.addModule("whirlpool-river", .{
        .root_source_file = b.path("src/river/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "whirlpool-model", .module = model }},
    });
    const layout = b.addModule("whirlpool-layout", .{
        .root_source_file = b.path("src/layout/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "whirlpool-model", .module = model }},
    });

    const snail_dep = b.dependency("snail", .{
        .target = target,
        .optimize = optimize,
    });
    const snail = snail_dep.module("snail");
    const snail_raster = snail_dep.module("snail-raster");
    const graphics = b.addModule("whirlpool-graphics", .{
        .root_source_file = b.path("src/graphics/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "snail", .module = snail },
            .{ .name = "snail-raster", .module = snail_raster },
        },
    });

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.generate("wl_compositor", 6);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("river_window_manager_v1", 5);

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });
    wayland.linkSystemLibrary("wayland-client", .{});

    const studio = b.addModule("whirlpool-studio", .{
        .root_source_file = b.path("src/platform/studio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "wayland", .module = wayland }},
    });
    studio.addImport("whirlpool-graphics", graphics);
    studio.linkSystemLibrary("wayland-client", .{});
    studio.linkSystemLibrary("vulkan", .{});

    const exe = b.addExecutable(.{
        .name = "whirlpool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "whirlpool-model", .module = model },
                .{ .name = "whirlpool-shell", .module = shell },
                .{ .name = "whirlpool-runtime", .module = runtime },
                .{ .name = "whirlpool-studio", .module = studio },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Whirlpool").dependOn(&run.step);

    const test_step = b.step("test", "Run all unit tests");
    inline for (.{ model, shell, runtime, river, layout, graphics }) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }

    const check = b.step("check", "Compile Whirlpool without installing it");
    check.dependOn(&exe.step);
}
