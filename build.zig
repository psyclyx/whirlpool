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

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.generate("wl_compositor", 6);
    scanner.generate("xdg_wm_base", 6);

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
    studio.linkSystemLibrary("wayland-client", .{});
    studio.linkSystemLibrary("wayland-egl", .{});
    studio.linkSystemLibrary("EGL", .{});
    studio.linkSystemLibrary("GLESv2", .{});

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
    inline for (.{ model, shell, runtime }) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }

    const check = b.step("check", "Compile Whirlpool without installing it");
    check.dependOn(&exe.step);
}
