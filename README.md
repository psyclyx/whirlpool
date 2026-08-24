# Whirlpool

Whirlpool is a new River window manager and graphical shell host. It is a
rewrite informed by Tidepool and Shoal, built around current Zig and Snail
rather than a source transplant from either project.

The accepted Zig/Lua ownership and capability boundary is documented in
[`docs/lua-architecture.md`](docs/lua-architecture.md). The dependency-aware,
parallel work schedule is in
[`docs/implementation-plan.md`](docs/implementation-plan.md).

River's v5 window-management protocol is vendored from the exact upstream
revision in `npins/sources.json`; the Nix build rejects any pin/vendor drift.

## Direction

- Whirlpool owns the River connection, window/output model, event loop, and
  graphics context.
- The Zig WM kernel is a pure, strongly tested state machine containing the
  scrolling column/split/tab model. It owns policy state but no protocol
  proxies, sockets, rendering handles, or Lua values.
- Lua owns configuration, rules, named actions, and retained shell composition.
  It reads immutable WM snapshots and emits typed semantic intents; River and
  graphics objects never cross the boundary.
- The shared retained UI/Snail library is the reusable part of the Shoal idea.
  Whirlpool owns its Wayland surfaces and one Vulkan graphics context.
- Graphical surfaces use explicit dma-buf `wl_buffer` objects with DRM syncobj
  acquire/release points. Buffer slots are allocated lazily under contention,
  within one visible graphics budget.
- `whirlpool studio` is the graphics iteration entry point. It creates an
  ordinary xdg-shell preview surface and exercises the same Lua, UI, Snail,
  Vulkan, dma-buf, and synchronization path without binding River's
  window-management protocols.

The checked-in source is still a bootstrap prototype: Studio currently uses a
Vulkan WSI swapchain and CPU-produced Snail pixels, while the placeholder model
implements only a small subset of the target WM. These modules will be replaced
at the subsystem boundaries described in the implementation plan rather than
preserved behind compatibility layers.

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
zig build run -- studio
nix-build
```

## Testing strategy

Window behavior is tested at three layers:

1. Pure model tests cover lifecycle, focus repair, tags, output removal, and
   cross-output moves with no compositor involved.
2. River trace tests replay representative staged events, assert ordered
   requests, and verify every started v5 manage/render sequence finishes.
3. Studio and a nested River smoke test cover real dma-buf synchronization,
   resize, commit, and destruction paths.

Most behavioral combinations belong in layer 1 so they stay deterministic,
fast, and easy to run under sanitizers and allocation checking. A configurable
many-surface mode records resource and update counters; it is a measurement
tool, not a compositor simulator.

## License

MIT. See [LICENSE](LICENSE).
