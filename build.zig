const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wm = b.addModule("whirlpool-wm", .{
        .root_source_file = b.path("src/wm/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ui = b.addModule("whirlpool-ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime = b.addModule("whirlpool-runtime", .{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const graphics = b.addModule("whirlpool-graphics", .{
        .root_source_file = b.path("src/graphics/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    graphics.addIncludePath(b.path("src/graphics"));
    addSkia(b, graphics);
    const script = b.addModule("whirlpool-script", .{
        .root_source_file = b.path("src/script/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "whirlpool-wm", .module = wm }},
    });
    const lua_stdlib = b.addModule("whirlpool-lua-stdlib", .{
        .root_source_file = b.path("lua/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const host = b.addModule("whirlpool-host", .{
        .root_source_file = b.path("src/host/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "whirlpool-wm", .module = wm },
            .{ .name = "whirlpool-ui", .module = ui },
            .{ .name = "whirlpool-graphics", .module = graphics },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-lua-stdlib", .module = lua_stdlib },
        },
    });
    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 9);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("zwp_linux_dmabuf_v1", 3);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("river_window_manager_v1", 5);
    scanner.generate("river_xkb_bindings_v1", 1);
    scanner.generate("river_layer_shell_v1", 1);

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });
    wayland.linkSystemLibrary("wayland-client", .{});

    const wayland_client = b.addModule("whirlpool-wayland-client", .{
        .root_source_file = b.path("src/platform/wayland/client/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "wayland", .module = wayland }},
    });
    wayland_client.linkSystemLibrary("wayland-client", .{});

    const wayland_event_loop = b.addModule("whirlpool-wayland-event-loop", .{
        .root_source_file = b.path("src/platform/wayland/event_loop/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wayland_layer_shell = b.addModule("whirlpool-wayland-layer-shell", .{
        .root_source_file = b.path("src/platform/wayland/layer_shell/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
        },
    });
    wayland_layer_shell.linkSystemLibrary("wayland-client", .{});

    const wayland_dmabuf = b.addModule("whirlpool-wayland-dmabuf", .{
        .root_source_file = b.path("src/platform/wayland/dmabuf/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
        },
    });
    wayland_dmabuf.linkSystemLibrary("wayland-client", .{});

    const river_keybindings = b.addModule("whirlpool-river-keybindings", .{
        .root_source_file = b.path("src/platform/river/keybindings/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-script", .module = script },
        },
    });

    const wayland_wsi = b.addModule("whirlpool-wayland-wsi", .{
        .root_source_file = b.path("src/graphics/wayland/wsi/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "whirlpool-graphics", .module = graphics }},
    });
    wayland_wsi.linkSystemLibrary("vulkan", .{});
    wayland_wsi.linkSystemLibrary("wayland-client", .{});
    for ([_][]const u8{ "vulkan", "wayland-client" }) |package| {
        const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", package });
        var tokens = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
        while (tokens.next()) |token| {
            if (std.mem.startsWith(u8, token, "-I"))
                wayland_wsi.addIncludePath(.{ .cwd_relative = token[2..] });
        }
    }

    const dmabuf_allocator = b.addModule("whirlpool-dmabuf-allocator", .{
        .root_source_file = b.path("src/graphics/dmabuf/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dmabuf_allocator.linkSystemLibrary("gbm", .{});
    dmabuf_allocator.linkSystemLibrary("vulkan", .{});

    const wayland_surface_presenter = b.addModule("whirlpool-wayland-surface-presenter", .{
        .root_source_file = b.path("src/platform/wayland/surface_presenter/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-wm", .module = wm },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-graphics", .module = graphics },
            .{ .name = "whirlpool-wayland-wsi", .module = wayland_wsi },
        },
    });
    const wayland_layer_shell_runtime = b.addModule("whirlpool-wayland-layer-shell-runtime", .{
        .root_source_file = b.path("src/platform/wayland/layer_shell/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-wayland-layer-shell", .module = wayland_layer_shell },
            .{ .name = "whirlpool-wayland-surface-presenter", .module = wayland_surface_presenter },
            .{ .name = "whirlpool-wayland-wsi", .module = wayland_wsi },
            .{ .name = "whirlpool-script", .module = script },
        },
    });
    wayland_layer_shell_runtime.linkSystemLibrary("wayland-client", .{});

    const wayland_runtime = b.addModule("whirlpool-wayland-runtime", .{
        .root_source_file = b.path("src/platform/wayland/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-wayland-event-loop", .module = wayland_event_loop },
        },
    });
    wayland_runtime.linkSystemLibrary("wayland-client", .{});

    const river_layer_shell = b.addModule("whirlpool-river-layer-shell", .{
        .root_source_file = b.path("src/platform/river/layer_shell/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
        },
    });
    river_layer_shell.linkSystemLibrary("wayland-client", .{});

    const river_live = b.addModule("whirlpool-river-live", .{
        .root_source_file = b.path("src/platform/river/live/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-river-layer-shell", .module = river_layer_shell },
        },
    });
    river_live.linkSystemLibrary("wayland-client", .{});
    const river_live_plans = b.addModule("whirlpool-river-live-plans", .{
        .root_source_file = b.path("src/platform/river/live/plans/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-wm", .module = wm },
            .{ .name = "whirlpool-river-live", .module = river_live },
        },
    });
    river_live_plans.linkSystemLibrary("wayland-client", .{});
    const river_live_world = b.addModule("whirlpool-river-live-world", .{
        .root_source_file = b.path("src/platform/river/live/world/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-wm", .module = wm },
        },
    });
    river_live_world.linkSystemLibrary("wayland-client", .{});
    const river_layout_runtime = b.addModule("whirlpool-river-layout-runtime", .{
        .root_source_file = b.path("src/platform/river/layout_runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-wm", .module = wm },
        },
    });
    const river_policy_runtime = b.addModule("whirlpool-river-policy-runtime", .{
        .root_source_file = b.path("src/platform/river/policy_runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-wm", .module = wm },
        },
    });
    const river_host_runtime = b.addModule("whirlpool-river-host-runtime", .{
        .root_source_file = b.path("src/platform/river/host/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-wm", .module = wm },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-river-live", .module = river_live },
            .{ .name = "whirlpool-river-live-plans", .module = river_live_plans },
            .{ .name = "whirlpool-river-live-world", .module = river_live_world },
        },
    });
    river_host_runtime.linkSystemLibrary("wayland-client", .{});
    const river_role_lifecycle = b.addModule("whirlpool-river-role-lifecycle", .{
        .root_source_file = b.path("src/platform/river/role_lifecycle/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-river-live", .module = river_live },
            .{ .name = "whirlpool-river-live-world", .module = river_live_world },
        },
    });
    river_role_lifecycle.linkSystemLibrary("wayland-client", .{});
    const river_presentation = b.addModule("whirlpool-river-presentation", .{
        .root_source_file = b.path("src/platform/river/presentation/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const river_presenter_runtime = b.addModule("whirlpool-river-presenter-runtime", .{
        .root_source_file = b.path("src/platform/river/presenter_runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-graphics", .module = graphics },
            .{ .name = "whirlpool-wayland-wsi", .module = wayland_wsi },
            .{ .name = "whirlpool-river-host-runtime", .module = river_host_runtime },
            .{ .name = "whirlpool-river-presentation", .module = river_presentation },
        },
    });

    // Application modules are intentionally narrow composition roots. Keeping
    // their imports explicit prevents startup code from reaching through to a
    // lower layer merely because the executable happens to know about it.
    const app_river_configured = b.addModule("whirlpool-app-river-configured", .{
        .root_source_file = b.path("src/app/river/configured/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-river-host-runtime", .module = river_host_runtime },
            .{ .name = "whirlpool-river-keybindings", .module = river_keybindings },
            .{ .name = "whirlpool-river-layout-runtime", .module = river_layout_runtime },
            .{ .name = "whirlpool-river-policy-runtime", .module = river_policy_runtime },
        },
    });
    const app_river_presentation = b.addModule("whirlpool-app-river-presentation", .{
        .root_source_file = b.path("src/app/river/presentation/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-wm", .module = wm },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-river-host-runtime", .module = river_host_runtime },
            .{ .name = "whirlpool-river-role-lifecycle", .module = river_role_lifecycle },
            .{ .name = "whirlpool-river-presenter-runtime", .module = river_presenter_runtime },
        },
    });
    const app_river = b.addModule("whirlpool-app-river", .{
        .root_source_file = b.path("src/app/river/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-wayland-runtime", .module = wayland_runtime },
            .{ .name = "whirlpool-river-live", .module = river_live },
            .{ .name = "whirlpool-river-host-runtime", .module = river_host_runtime },
            .{ .name = "whirlpool-river-role-lifecycle", .module = river_role_lifecycle },
            .{ .name = "whirlpool-app-river-configured", .module = app_river_configured },
            .{ .name = "whirlpool-app-river-presentation", .module = app_river_presentation },
        },
    });
    const app_layer_shell = b.addModule("whirlpool-app-layer-shell", .{
        .root_source_file = b.path("src/app/layer_shell/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-wayland-client", .module = wayland_client },
            .{ .name = "whirlpool-wayland-runtime", .module = wayland_runtime },
            .{ .name = "whirlpool-wayland-layer-shell-runtime", .module = wayland_layer_shell_runtime },
        },
    });

    const exe = b.addExecutable(.{
        .name = "whirlpool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "whirlpool-runtime", .module = runtime },
                .{ .name = "whirlpool-app-river", .module = app_river },
                .{ .name = "whirlpool-app-layer-shell", .module = app_layer_shell },
            },
        }),
    });
    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("lua"),
        .install_dir = .prefix,
        .install_subdir = "share/whirlpool/lua",
        .exclude_extensions = &.{"zig"},
    });

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Whirlpool").dependOn(&run.step);

    const test_step = b.step("test", "Run all unit tests");
    const graphics_test_step = b.step("graphics-test", "Run graphics and Vulkan WSI tests");
    inline for (.{
        wm,
        ui,
        runtime,
        host,
        script,
        wayland_client,
        wayland_event_loop,
        wayland_layer_shell,
        wayland_dmabuf,
        wayland_surface_presenter,
        wayland_layer_shell_runtime,
        wayland_runtime,
        river_layer_shell,
        river_live,
        river_keybindings,
        river_live_plans,
        river_live_world,
        river_layout_runtime,
        river_policy_runtime,
        river_host_runtime,
        river_role_lifecycle,
        river_presentation,
        river_presenter_runtime,
        app_river_configured,
        app_river_presentation,
        app_river,
        app_layer_shell,
    }) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
    inline for (.{ graphics, dmabuf_allocator, wayland_wsi }) |module| {
        const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
        test_step.dependOn(&run_tests.step);
        graphics_test_step.dependOn(&run_tests.step);
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/script/lua_vm.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    })).step);
    const check = b.step("check", "Compile Whirlpool without installing it");
    check.dependOn(&exe.step);
}

/// Build the C++ ABI membrane with the same pkg-config/g++ discipline used
/// by the weft application. Only the C ABI in shim.h crosses into Zig.
fn addSkia(b: *std.Build, module: *std.Build.Module) void {
    const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", "skia" });
    const fontconfig_cflags = b.run(&.{ "pkg-config", "--cflags-only-I", "fontconfig" });
    const libstdcpp = std.mem.trim(u8, b.run(&.{ "g++", "-print-file-name=libstdc++.so" }), " \t\r\n");
    const compile = b.addSystemCommand(&.{ "g++", "-std=c++17", "-c", "-O2", "-fPIC", "-fno-rtti", "-fno-exceptions" });
    var tokens = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
    while (tokens.next()) |token| compile.addArg(b.dupe(token));
    var fontconfig_tokens = std.mem.tokenizeAny(u8, fontconfig_cflags, " \t\r\n");
    while (fontconfig_tokens.next()) |token| compile.addArg(b.dupe(token));
    compile.addFileArg(b.path("src/graphics/skia/shim.cpp"));
    compile.addArg("-o");
    const object = compile.addOutputFileArg("whirlpool_skia_shim.o");
    module.addObjectFile(object);
    module.linkSystemLibrary("skia", .{});
    module.linkSystemLibrary("fontconfig", .{});
    module.addObjectFile(.{ .cwd_relative = libstdcpp });
}
