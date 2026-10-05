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
    graphics.linkSystemLibrary("vulkan", .{});
    const script = b.addModule("whirlpool-script", .{
        .root_source_file = b.path("src/script/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "whirlpool-wm", .module = wm }},
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
    scanner.generate("river_xkb_bindings_v1", 3);
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

    const dmabuf_allocator = b.addModule("whirlpool-dmabuf-allocator", .{
        .root_source_file = b.path("src/graphics/dmabuf/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "whirlpool-graphics", .module = graphics }},
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
            .{ .name = "whirlpool-wayland-dmabuf", .module = wayland_dmabuf },
            .{ .name = "whirlpool-dmabuf-allocator", .module = dmabuf_allocator },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-graphics", .module = graphics },
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
            .{ .name = "whirlpool-wayland-dmabuf", .module = wayland_dmabuf },
            .{ .name = "whirlpool-dmabuf-allocator", .module = dmabuf_allocator },
            .{ .name = "whirlpool-host", .module = host },
            .{ .name = "whirlpool-script", .module = script },
            .{ .name = "whirlpool-graphics", .module = graphics },
            .{ .name = "whirlpool-river-host-runtime", .module = river_host_runtime },
            .{ .name = "whirlpool-river-presentation", .module = river_presentation },
        },
    });

    // Application modules are intentionally narrow composition roots. Keeping
    // their imports explicit prevents startup code from reaching through to a
    // lower layer merely because the executable happens to know about it.
    const app_status = b.addModule("whirlpool-app-status", .{
        .root_source_file = b.path("src/app/status/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app_desktop_entries = b.addModule("whirlpool-app-desktop-entries", .{
        .root_source_file = b.path("src/app/desktop_entries/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
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
            .{ .name = "whirlpool-app-status", .module = app_status },
            .{ .name = "whirlpool-app-desktop-entries", .module = app_desktop_entries },
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
            .{ .name = "whirlpool-app-status", .module = app_status },
        },
    });

    // LLVM for every artifact: Zig 0.16's own x86_64 backend (its Debug
    // default) passes C functions the floats that spill onto the stack in
    // the wrong places, and the Skia shim takes many.
    const use_llvm = true;
    const exe = b.addExecutable(.{
        .name = "whirlpool",
        .use_llvm = use_llvm,
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
    // The Lua library is plain files; packaging can install it separately, so
    // changing it does not rebuild Zig.
    if (b.option(bool, "install-lua", "Install the Lua library (default: true)") orelse true) {
        b.installDirectory(.{
            .source_dir = b.path("lua"),
            .install_dir = .prefix,
            .install_subdir = "share/whirlpool/lua",
            .exclude_extensions = &.{"zig"},
        });
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Whirlpool").dependOn(&run.step);

    const shell_bench = b.addExecutable(.{
        .name = "whirlpool-shell-bench",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_shell.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "whirlpool-host", .module = host },
                .{ .name = "whirlpool-script", .module = script },
                .{ .name = "whirlpool-graphics", .module = graphics },
                .{ .name = "whirlpool-app-status", .module = app_status },
            },
        }),
    });
    const run_shell_bench = b.addRunArtifact(shell_bench);
    b.step("bench-shell", "Benchmark example shell frame phases").dependOn(&run_shell_bench.step);

    const shell_preview = b.addExecutable(.{
        .name = "whirlpool-shell-preview",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell_preview.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "whirlpool-host", .module = host },
                .{ .name = "whirlpool-script", .module = script },
                .{ .name = "whirlpool-graphics", .module = graphics },
                .{ .name = "whirlpool-app-status", .module = app_status },
            },
        }),
    });
    const run_shell_preview = b.addRunArtifact(shell_preview);
    if (b.args) |args| run_shell_preview.addArgs(args);
    b.step("shell-preview", "Render the example shell to PPM images").dependOn(&run_shell_preview.step);

    const test_step = b.step("test", "Run all unit tests");
    const graphics_test_step = b.step("graphics-test", "Run graphics and DMA-BUF tests");
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
        app_desktop_entries,
        app_river_presentation,
        app_river,
        app_layer_shell,
    }) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module, .use_llvm = use_llvm })).step);
    }
    inline for (.{ graphics, dmabuf_allocator }) |module| {
        const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = module, .use_llvm = use_llvm }));
        test_step.dependOn(&run_tests.step);
        graphics_test_step.dependOn(&run_tests.step);
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .use_llvm = use_llvm,
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

/// Build the C++ ABI membrane. Only the C ABI in shim.h crosses into Zig.
fn addSkia(b: *std.Build, module: *std.Build.Module) void {
    // Skia is compiled by Zig as a static library against Zig's libc++ (see
    // nix/packages/whirlpool-skia.nix), and so is this shim: one C++
    // toolchain and runtime throughout.
    module.link_libcpp = true;
    var flags = std.ArrayList([]const u8).empty;
    flags.appendSlice(b.allocator, &.{ "-std=c++17", "-fno-rtti", "-fno-exceptions" }) catch @panic("OOM");
    for ([_][]const u8{ "skia", "fontconfig", "librsvg-2.0" }) |package| {
        const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", package });
        var tokens = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
        while (tokens.next()) |token| flags.append(b.allocator, b.dupe(token)) catch @panic("OOM");
    }
    module.addCSourceFile(.{
        .file = b.path("src/graphics/skia/shim.cpp"),
        .flags = flags.items,
        .language = .cpp,
    });
    module.linkSystemLibrary("skia", .{ .preferred_link_mode = .static });
    // What a static Skia leaves to be linked.
    for ([_][]const u8{ "fontconfig", "freetype2", "libpng", "libwebp", "libwebpmux", "libwebpdemux", "libjpeg", "zlib", "expat" }) |library|
        module.linkSystemLibrary(library, .{});
    module.linkSystemLibrary("rsvg-2", .{});
}
