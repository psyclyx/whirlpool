const std = @import("std");

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
