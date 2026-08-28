# Codebase structure audit

This audit treats size as a prompt to inspect cohesion, not as a defect by
itself. A type should own one state machine or one resource lifetime. Protocol
decoding, policy, storage, and presentation should meet at typed values rather
than through forwarding methods.

## Rules used in this pass

- Keep generated-protocol callbacks at platform edges.
- Keep WM policy and topology free of Wayland, Lua, UI, and graphics types.
- Prefer borrowed views for synchronous reads and explicitly-owned values for
  durable work.
- Put fallible validation and allocation before transaction commit edges.
- Do not add pass-through methods merely to hide an already-typed subsystem.
- Split by ownership or state machine, never by an arbitrary line target.

## Completed structural changes

- The WM world exposes semantic atomic commands and borrowed `WorldView`
  values; tree and policy implementation remain separate modules.
- River proxy identity is owned by `live_objects.Registry`; protocol event
  decoding lives in `live/listeners.zig` and `live_world/events.zig`.
- Host listener callbacks and configured-action lowering have dedicated
  modules instead of inflating `host_runtime.Runtime`.
- Lua configuration is an owned `Config`; key/action extraction is isolated in
  `config/bindings.zig`.
- Lua layout input is pushed as typed tables rather than generated source.
- Lua ABI loading has one owner in `lua_vm.zig`; callback users borrow its
  callback API.
- UI animation and signals are separate concerns; signal subscriptions no
  longer retain raw owner pointers.
- River render preflight resolves every surface role before the infallible
  synchronized-commit edge.
- Dead external-Vulkan Skia plumbing and its unused C/C++ bridge were removed.

## File-by-file disposition

### Entrypoint, build, and operations

| File | Disposition |
| --- | --- |
| `src/main.zig` | Cohesive argument parsing and application-mode dispatch. |
| `src/app/river.zig` | Cohesive River application startup, disconnect order, and post-dispatch orchestration. |
| `src/app/layer_shell.zig` | Cohesive portable layer-shell startup and post-dispatch loop. |
| `src/app/river_presentation.zig` | Cohesive River role-to-presenter lifetime bridge. |
| `build.zig` | Correct dependency authority, but repeated module/test wiring should be collapsed behind small build helpers when the current feature matrix stabilizes. |
| `src/runtime/root.zig` | Cohesive CLI/runtime export root. |
| `src/runtime/ipc.zig` | Cohesive typed IPC vocabulary and parser. |
| `src/runtime/lifecycle.zig` | Cohesive runtime lifecycle state machine. |
| `src/runtime/persistence.zig` | Cohesive persistence boundary. |
| `README.md` | Current high-level behavior; keep implementation detail in architecture docs. |
| `docs/implementation-plan.md` | Current operational priorities, not an alternate architecture specification. |
| `docs/lua-architecture.md` | Current Lua/surface/presentation boundaries. |
| `docs/operational-smoke.md` | Cohesive manual validation procedure. |
| `scripts/smoke-common.sh` | Shared smoke setup; no policy logic. |
| `scripts/compositor-free-smoke.sh` | Cohesive fast smoke entrypoint. |
| `scripts/nested-river-smoke.sh` | Cohesive nested-compositor smoke entrypoint. |
| `default.nix`, `nix/shell.nix`, `nix/packages/whirlpool.nix` | Packaging and development environments are appropriately separate; keep feature flags sourced from the package expression. |
| `build.zig.zon`, `build.zig.zon.nix`, `npins/default.nix`, `npins/sources.json` | Dependency pinning only; no runtime architecture belongs here. |

### Window-management kernel

| File | Disposition |
| --- | --- |
| `src/wm/root.zig` | Thin public vocabulary/export root. |
| `src/wm/ids.zig` | Cohesive generation-checked identity primitives. |
| `src/wm/types.zig` | Cohesive owned domain records. A tagged node payload remains a worthwhile later change if nullable leaf/container fields continue spreading checks. |
| `src/wm/command.zig` | Cohesive semantic command vocabulary; output-scoped directional operations remove hidden focus selection. |
| `src/wm/world.zig` | Reduced orchestration boundary. Keep storage and queries here; do not restore forwarding wrappers for tree or policy operations. |
| `src/wm/world_tree.zig` | Cohesive topology mutation implementation. |
| `src/wm/world_policy.zig` | Cohesive focus, placement, and policy implementation. A dedicated mark registry is the next change if mark operations expand. |
| `src/wm/world_snapshot.zig` | Cohesive borrowed view and explicit owned checkpoint boundary. |
| `src/wm/world_validation.zig` | Cohesive invariant checker. |
| `src/wm/lifecycle.zig` | Cohesive compositor-lifecycle translation. |
| `src/wm/layout.zig` | Cohesive renderer-neutral plans sharing `PlanContext`. |
| `src/wm/input.zig` | Cohesive semantic input planning. |
| `src/wm/world_test.zig` | Broad kernel behavior tests belong outside the implementation files at this size. |

### Script and Lua boundary

| File | Disposition |
| --- | --- |
| `src/script/root.zig` | Thin public export and intent vocabulary. |
| `src/script/config.zig` | Owns assembled configuration plus layout/surface loading. Surface parsing can move to `config/surfaces.zig` if that schema grows. |
| `src/script/config/bindings.zig` | Cohesive binding/action schema, key decoding, ownership, and duplicate validation. |
| `src/script/lua_vm.zig` | Sole dynamic Lua ABI owner and protected VM operations. Instruction-hook routing is the only remaining thread-local seam and should be replaced if concurrent VMs become supported. |
| `src/script/program_loader.zig` | Program ownership is cohesive; move the retained-node Lua callback bridge to `program_loader/bridge.zig` next so loading and execution adapters are not one file. |
| `src/script/wm_bridge.zig` | Cohesive conversion from script intents to semantic WM commands. |
| `lua/root.zig` | Lua package source aggregation only. |
| `lua/whirlpool/init.lua` | Public Lua constructors and action vocabulary. |
| `lua/whirlpool/workspace.lua` | Cohesive workspace service convention. |
| `config/whirlpool.lua` | Supported user configuration example. |
| `config/lib/scrolling.lua` | Replaceable scrolling layout policy, correctly outside native WM mechanics. |

### Retained UI

| File | Disposition |
| --- | --- |
| `src/ui/root.zig` | Thin public export root. |
| `src/ui/arena.zig` | Cohesive generation-checked storage primitive. |
| `src/ui/properties.zig` | Cohesive property vocabulary, validation, and ownership. |
| `src/ui/tree.zig` | `Scene` owns retained nodes and mount lifetimes; size is mostly topology code and tests. If it grows, extract snapshot copying, not forwarding methods. |
| `src/ui/scene.zig` | Cohesive atomic scene-delta transaction. |
| `src/ui/signal.zig` | Cohesive signal ownership and inert subscription identities. |
| `src/ui/animation.zig` | Cohesive animation clock/interpolation behavior. |
| `src/ui/target.zig` | Cohesive renderer-neutral target interface. |

### Host-neutral adapters

| File | Disposition |
| --- | --- |
| `src/host/root.zig` | Thin host package export root. |
| `src/host/types.zig` | Canonical platform-neutral River facts and operations. |
| `src/host/proxy_maps.zig` | Cohesive bidirectional proxy/identity maps. |
| `src/host/staged_facts.zig` | Generic owned fact batches and staging. |
| `src/host/phase.zig` | Cohesive callback/phase guard. |
| `src/host/wm_bridge.zig` | Cohesive WM-plan to host-plan identity translation. |
| `src/host/composition.zig` | Cohesive frame-plan composition. |
| `src/host/surface_composition.zig` | Cohesive surface transaction abstraction. |
| `src/host/river_coordinator.zig` | Cohesive render ordering and finish guarantee; synchronized surface commits now begin only after role preflight. |
| `src/host/lua_composition.zig` | Still combines Lua callback decoding and scene-delta lowering. Split into `lua_composition/decode.zig` and `lower.zig` when new property types arrive. |
| `src/host/skia_scene.zig` | Cohesive retained-scene to draw-list lowering. |

### River platform

| File | Disposition |
| --- | --- |
| `src/platform/river/live.zig` | Manager owns protocol objects, roles, and legal transaction states. Generated callback dispatch has moved out. |
| `src/platform/river/live/listeners.zig` | Cohesive generated-event adapter for `live.Manager`. |
| `src/platform/river/live_objects.zig` | Cohesive River proxy identity registry. Typed and erased bind helpers are intentional boundary variants, not forwarding layers. |
| `src/platform/river/live_world.zig` | Owns staging and manage/render cycle orchestration. Frame construction can move next if more plan providers appear. |
| `src/platform/river/live_world/events.zig` | Cohesive child-event to host-fact decoding. |
| `src/platform/river/live_world/reconcile.zig` | Cohesive mandatory River lifecycle reconciliation into the WM kernel. |
| `src/platform/river/live_plans.zig` | Cohesive host-operation to generated-request encoder. |
| `src/platform/river/host_runtime.zig` | Owns transaction scheduling and delegates pending surface ownership to `SurfaceQueue`. |
| `src/platform/river/host_runtime/listeners.zig` | Cohesive callback-depth and fact-staging edge. |
| `src/platform/river/host_runtime/surface_queue.zig` | Cohesive bounded submission ownership, cancellation, discard, and completion. |
| `src/platform/river/configured_actions.zig` | Cohesive configured-action lowering and spawn seam. |
| `src/platform/river/input_intents.zig` | Cohesive bounded input intent queue. |
| `src/platform/river/keybindings.zig` | Cohesive XKB binding lifetime. Per-seat protocol state should stay here if protocol version support expands. |
| `src/platform/river/layer_shell.zig` | Cohesive River layer-shell manager adapter. |
| `src/platform/river/decoration_lifecycle.zig` | Cohesive decoration selection diff. |
| `src/platform/river/role_lifecycle.zig` | Cohesive shell/decoration role ownership and retirement. |
| `src/platform/river/policy_runtime.zig` | Cohesive bounded Lua WM policy runtime. |
| `src/platform/river/layout_runtime.zig` | Runtime type is small; free functions encode/decode layout tables. Split codecs only if the schema gains another version. |
| `src/platform/river/presentation.zig` | Cohesive generic presenter registry and strict retirement state machine; much of its size is direct state-transition testing. |
| `src/platform/river/presenter_runtime.zig` | Cohesive concrete Skia/WSI presenter aggregate. |

### Wayland and graphics platform

| File | Disposition |
| --- | --- |
| `src/platform/wayland/root.zig` | Thin export root. |
| `src/platform/wayland/client.zig` | Cohesive registry/client ownership. |
| `src/platform/wayland/runtime.zig` | Cohesive session wrapper with a real wake pipe. |
| `src/platform/wayland/event_loop.zig` | Poll/wake and callback scheduling are related but separable; extract the poll backend if another transport is added. |
| `src/platform/wayland/layer_shell.zig` | Cohesive generated layer-shell role owner. |
| `src/platform/wayland/layer_runtime.zig` | Cohesive portable layer-shell application runtime. |
| `src/platform/wayland/surface_presenter.zig` | Cohesive Skia-to-WSI presenter state machine. |
| `src/graphics/root.zig` | Thin graphics export root. |
| `src/graphics/skia.zig` | Cohesive draw-list/frame wrapper around the local C++ shim. |
| `src/graphics/skia/shim.h`, `src/graphics/skia/shim.cpp` | Minimal C ABI and Skia implementation; unused external-Vulkan ownership paths were removed. |
| `src/graphics/wayland_wsi.zig` | Already split internally into display/device `Context` and per-surface `Swapchain`; keep together while they share one Vulkan vocabulary. Add failure-injection tests before further structural changes. |

Protocol XML files are upstream interface definitions, not application code;
they are compiled into typed edges and should not accumulate Whirlpool policy.

## Remaining order of work

1. Move the retained-node Lua callback bridge out of `program_loader.zig`.
2. Add WSI allocation/failure tests before changing its resource layout.

These are structural changes only. None requires dropping configuration,
layout, shell, decoration, input, rendering, or presentation behavior.
