# Whirlpool

Whirlpool is a new River window manager and graphical shell host. It is a
rewrite informed by Tidepool and Shoal, built around current Zig and Skia
rather than a source transplant from either project.

The accepted Zig/Lua ownership and callback boundary is documented in
[`docs/lua-architecture.md`](docs/lua-architecture.md). The dependency-aware,
parallel work schedule is in
[`docs/implementation-plan.md`](docs/implementation-plan.md).

River's v5 window-management protocol is vendored from the exact upstream
revision in `npins/sources.json`; the Nix build rejects any pin/vendor drift.

## Direction

- Whirlpool owns the River connection, window/output model, event loop, and
  graphics context.
- The Zig WM kernel is a pure, strongly tested state machine. It owns durable
  compositor state but no protocol proxies, sockets, rendering handles, Lua
  values, or user layout algorithms.
- Lua owns configuration, rules, named actions, and retained shell composition.
  It reads immutable WM snapshots and emits typed semantic intents; River and
  graphics objects never cross the boundary.
- The shared retained UI and renderer-neutral draw contract are the reusable
  part of the Shoal idea. Skia owns native 2D rasterization; Whirlpool owns its
  Wayland surfaces and one Vulkan graphics context.
- Graphical surfaces use Vulkan Wayland swapchains; Vulkan WSI owns buffer
  exchange and presentation synchronization.
- Wayland surface roles are adapters. River shell roles provide integrated WM
  UI; layer-shell roles provide portable panels and overlays under other
  compositors without changing the UI composition.

The checked-in source contains a generation-checked WM kernel with lifecycle
reconciliation, retained UI composition, callback-lifetime Lua WM snapshots
and typed intents, PUC Lua protected calls, generated Wayland registry and
River-manager lifecycle, and same-epoch WM-plan translation. The River path has live
window/output/seat facts, same-epoch plan application, per-output shell-role
ownership, WM-driven decoration selection, and bounded named input intents.
The River path now registers a concrete per-role Skia/Vulkan presenter factory:
retained scenes are rasterized by Skia and presented through the standard
`VK_KHR_wayland_surface` and `VK_KHR_swapchain` extensions. River's role
transaction stays responsible only for its sync-next-commit boundary.

## Development

Enter the pinned development environment with direnv or Nix:

```sh
direnv allow
nix-shell -A shell
```

Common commands:

```sh
zig build test
zig build check
nix-build
nix-build -A whirlpool-nested
```

Run only the configured portable UI surfaces under the current compositor:

```sh
"$(nix-build -A packages.whirlpool)"/bin/whirlpool layer-shell \
  --config "$PWD/config/whirlpool.lua"
```

The checked-in River setup is `config/whirlpool.lua`; run it in a nested River
from a source checkout with:

```sh
timeout 15 "$(nix-build -A whirlpool-nested)/bin/whirlpool-nested" \
  --config "$PWD/config/whirlpool.lua"
```

The Nix attribute `whirlpool-nested` packages the same launcher and defaults
to the installed config and Lua module path. The sample is the Whirlpool/Lua
equivalent of the Tidepool/Shoal desktop: an Alt-based window-management map,
a bottom bar with workspace, minimap, focused-window, system-status, and clock
widgets, an audio OSD, and title/tab decorations. The same retained shell
content is used by River's integrated shell role and the portable layer-shell
adapter; River additionally supplies live desktop state and bar interaction.

## Testing strategy

Window behavior is tested at three layers:

1. Pure model tests cover lifecycle, focus repair, tags, output removal, and
   cross-output moves with no compositor involved.
2. River trace tests replay representative staged events, assert ordered
   requests, and verify every started v5 manage/render sequence finishes.
3. Surface-host and nested-host fixtures cover generated role lifecycles,
   resize, commit ordering, and destruction paths. The production Nix graph also
   type-checks and tests the real Skia/Vulkan River presenter runtime.

Most behavioral combinations belong in layer 1 so they stay deterministic,
fast, and easy to run under sanitizers and allocation checking. A configurable
many-surface mode records resource and update counters; it is a measurement
tool, not a compositor simulator.

## License

MIT. See [LICENSE](LICENSE).
