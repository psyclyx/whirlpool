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
- Treat programmer errors as assertions and external failures as errors. State
  owners check their invariants before and after mutation in safety builds.
- Use directories for owned subdomains and module-level functions for
  stateless transformations. Do not replace a large type with a namespace
  struct full of functions.
- Use small comptime adapters where callback signatures repeat mechanically;
  keep the concrete dependency mapping visible at the call site.
- Enforce architectural seams with `build.zig` modules when code crosses a
  package boundary. Relative imports remain appropriate inside one owner.
- Name every named `build.zig` module entry point `root.zig` and place it in a
  directory named for the module. Reserve `main.zig` for executable entry
  points and descriptive filenames for ordinary implementation files.
- Use `/` only for ownership or layering. Keep words joined with `_` when they
  form one technical noun (`layer_shell`, `event_loop`, `surface_presenter`);
  never manufacture a namespace by splitting a compound name.

## Completed structural changes

- The WM world exposes semantic atomic commands and borrowed `WorldView`
  values; tree and policy implementation remain separate modules.
- River proxy identity is owned by `live_objects.Registry`; protocol event
  decoding lives in `live/listeners.zig` and `live/world/events.zig`.
- Host listener callbacks and configured-action lowering have dedicated
  modules instead of inflating the River host `Runtime`.
- Lua configuration is an owned `Config`; key/action extraction is isolated in
  `config/bindings.zig`.
- Lua layout input is pushed as typed tables rather than generated source.
- Lua ABI loading has one owner in `lua_vm.zig`; callback users borrow its
  callback API.
- UI animation and signals are separate concerns; signal subscriptions no
  longer retain raw owner pointers.
- River render preflight resolves every surface role before the infallible
  synchronized-commit edge.
- Skia's external-Vulkan bridge is the production raster path; CPU pixel
  frames remain only for focused renderer tests.
- Executable startup can import only runtime and the two application modules.
  River configuration, presentation, host, and platform assemblies each have
  explicit build-module dependencies.
- WM semantic dispatch is separate from World storage; generation stores and
  the World validate their invariants around mutations.
- Program source loading, the retained-program contract, and Lua callback
  execution are separate modules. Operation budgets are enforced before sink
  mutation.
- River host policy collection and transport callbacks are localized under
  `host/`; transport is divided into driver, resolver, and surface edges.
- Vulkan WSI, swapchains, staging uploads, and their production callers were
  removed. DMA-BUF allocation, Vulkan import, Wayland import, and release
  ownership are separate explicit resource owners.

## File-by-file disposition

### Entrypoint, build, and operations

| File | Disposition |
| --- | --- |
| `src/main.zig` | Cohesive argument parsing and application-mode dispatch. |
| `src/app/river/root.zig` | Cohesive River application startup, disconnect order, and post-dispatch orchestration. |
| `src/app/layer_shell/root.zig` | Cohesive portable layer-shell startup and post-dispatch loop. |
| `src/app/river/presentation/root.zig` | Cohesive River role-to-presenter lifetime bridge. |
| `src/app/river/configured/root.zig` | Owns config-derived policy, layout, and keybinding services borrowed by River startup. |
| `build.zig` | Dependency authority. Application composition roots have narrow imports; module tests use one comptime tuple without hiding dependencies. |
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
| `src/wm/world/apply.zig` | Semantic command dispatch for a private atomic World candidate. |
| `src/wm/world/tree.zig` | Cohesive topology mutation implementation. |
| `src/wm/world/policy.zig` | Cohesive focus, placement, and policy implementation. A dedicated mark registry is the next change if mark operations expand. |
| `src/wm/world/snapshot.zig` | Cohesive borrowed view and explicit owned checkpoint boundary. |
| `src/wm/world/validation.zig` | Cohesive invariant checker. |
| `src/wm/lifecycle.zig` | Cohesive compositor-lifecycle translation. |
| `src/wm/layout.zig` | Cohesive renderer-neutral plans sharing `PlanContext`. |
| `src/wm/input.zig` | Cohesive semantic input planning. |
| `src/wm/world/test.zig` | Broad kernel behavior tests belong outside the implementation files at this size. |

### Script and Lua boundary

| File | Disposition |
| --- | --- |
| `src/script/root.zig` | Thin public export and intent vocabulary. |
| `src/script/config.zig` | Owns assembled configuration plus layout/surface loading. Surface parsing can move to `config/surfaces.zig` if that schema grows. |
| `src/script/config/bindings.zig` | Cohesive binding/action schema, key decoding, ownership, and duplicate validation. |
| `src/script/lua_vm.zig` | Sole dynamic Lua ABI owner and protected VM operations. Instruction-hook routing is the only remaining thread-local seam and should be replaced if concurrent VMs become supported. |
| `src/script/program/loader.zig` | Validates, copies, and owns explicitly supplied modules and the selected entry. |
| `src/script/program/contract.zig` | Data-only retained-program limits, values, node operations, updates, and sink contract. |
| `src/script/program/bridge.zig` | Bounded Lua callback execution; operation limits are checked before host mutation. |
| `src/script/wm_bridge.zig` | Cohesive conversion from script intents to semantic WM commands. |
| `lua/root.zig` | Lua package source aggregation only. |
| `lua/whirlpool/init.lua` | Public Lua constructors and action vocabulary. |
| `lua/whirlpool/workspace.lua` | Cohesive workspace service convention. |
| `lua/whirlpool/theme.lua` | Shared theme data and color blending. |
| `lua/whirlpool/status.lua` | Throttled operating-system status sampling and histories. Its synchronous command probes are the main remaining hidden-cost seam. |
| `lua/whirlpool/shell.lua` | Retained bottom bar, system widgets, minimap, and audio OSD policy. |
| `lua/whirlpool/decorator.lua` | Retained focused-title and tab-decoration policy. |
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
| `src/host/lua/composition.zig` | Owns retained scene batching, node identities, and snapshot/lowering orchestration. |
| `src/host/lua/properties.zig` | Stateless script-value to UI-delta property decoding. |
| `src/host/skia_scene.zig` | Cohesive retained-scene to draw-list lowering. |

### River platform

| File | Disposition |
| --- | --- |
| `src/platform/river/live/root.zig` | Manager owns protocol objects, roles, and legal transaction states. Generated callback dispatch has moved out. |
| `src/platform/river/live/listeners.zig` | Cohesive generated-event adapter for `live.Manager`. |
| `src/platform/river/live/world/objects.zig` | Cohesive River proxy identity registry. Typed and erased bind helpers are intentional boundary variants, not forwarding layers. |
| `src/platform/river/live/world/root.zig` | Owns staging and manage/render cycle orchestration. Frame construction can move next if more plan providers appear. |
| `src/platform/river/live/world/events.zig` | Cohesive child-event to host-fact decoding. |
| `src/platform/river/live/world/reconcile.zig` | Cohesive mandatory River lifecycle reconciliation into the WM kernel. |
| `src/platform/river/live/plans/root.zig` | Cohesive host-operation to generated-request encoder. |
| `src/platform/river/host/root.zig` | Owns transaction scheduling and delegates pending surface ownership to `SurfaceQueue`. |
| `src/platform/river/host/listeners.zig` | Cohesive callback-depth and fact-staging edge. |
| `src/platform/river/host/surface_queue.zig` | Cohesive bounded submission ownership, cancellation, discard, and completion. |
| `src/platform/river/host/actions.zig` | Cohesive configured-action lowering and spawn seam. |
| `src/platform/river/host/policy.zig` | Collects input, configured, and Lua policy intents into one atomic WM batch. |
| `src/platform/river/host/transport/root.zig` | Small composition root selecting live or injected transport edges. |
| `src/platform/river/host/transport/driver.zig` | Injected-driver manage transport used by compositor-free integration tests. |
| `src/platform/river/host/transport/resolver.zig` | Typed host-identity to River-proxy resolution; one comptime callback generator removes mechanical wrappers. |
| `src/platform/river/host/transport/surface.zig` | Synchronized surface preflight, commit, discard, and render emission. |
| `src/platform/river/live/world/input.zig` | Cohesive bounded input intent queue. |
| `src/platform/river/keybindings/root.zig` | Cohesive XKB binding lifetime. Per-seat protocol state should stay here if protocol version support expands. |
| `src/platform/river/layer_shell/root.zig` | Cohesive River layer-shell manager adapter. |
| `src/host/decoration_selection.zig` | Cohesive decoration selection diff. |
| `src/platform/river/role_lifecycle/root.zig` | Cohesive shell/decoration role ownership and retirement. |
| `src/platform/river/policy_runtime/root.zig` | Cohesive bounded Lua WM policy runtime. |
| `src/platform/river/layout_runtime/root.zig` | Runtime type is small; free functions encode/decode layout tables. Split codecs only if the schema gains another version. |
| `src/platform/river/presentation/root.zig` | Cohesive generic presenter registry and strict retirement state machine; much of its size is direct state-transition testing. |
| `src/platform/river/presenter_runtime/root.zig` | Concrete asynchronous River role presenter with coalesced Lua updates and a bounded DMA-BUF pool. |

### Wayland and graphics platform

| File | Disposition |
| --- | --- |
| `src/platform/wayland/client/root.zig` | Cohesive registry/client ownership. |
| `src/platform/wayland/runtime/root.zig` | Cohesive session wrapper with a real wake pipe. |
| `src/platform/wayland/event_loop/root.zig` | Lower-level poll/wake and callback scheduling contract imported explicitly by the concrete Wayland runtime. |
| `src/platform/wayland/layer_shell/root.zig` | Cohesive generated layer-shell role owner. |
| `src/platform/wayland/layer_shell/runtime/root.zig` | Cohesive portable layer-shell application runtime. |
| `src/platform/wayland/surface_presenter/root.zig` | Asynchronous ordinary-surface presenter; workers render directly into a bounded DMA-BUF pool while the Wayland thread owns attach, commit, and release. |
| `src/platform/wayland/dmabuf/root.zig` | Linux-DMA-BUF protocol capability, import, and `wl_buffer.release` ownership. |
| `src/graphics/root.zig` | Thin graphics export root. |
| `src/graphics/skia.zig` | Cohesive CPU and external-Vulkan draw-list wrappers around the local C++ shim. Production presentation uses the Vulkan path. |
| `src/graphics/skia/shim.h`, `src/graphics/skia/shim.cpp` | Minimal C ABI and Skia implementation, including direct Ganesh rendering into imported Vulkan images. |
| `src/graphics/dmabuf/root.zig` | Modifier-explicit GBM allocation and exported plane ownership. |
| `src/graphics/dmabuf/vulkan.zig` | WSI-free Vulkan device selection, external-memory import, DRM modifier negotiation, and foreign queue-family ownership. |

Protocol XML files are upstream interface definitions, not application code;
they are compiled into typed edges and should not accumulate Whirlpool policy.

## Deliberate non-splits

- `wm/world/tree.zig` and `wm/world/policy.zig` are algorithm modules operating
  on one authoritative World; turning each operation into an object would
  distribute the invariant rather than localize it.
- `ui/tree.zig` contains two real state owners, `Scene` and `MountContext`.
  Its size includes direct topology tests; snapshot extraction is justified
  only if another snapshot consumer or representation appears.
- `platform/river/presentation/root.zig` is one strict presenter-retirement state
  machine. Its small vtable wrapper is intentional dynamic dispatch, not a
  namespace struct.
- `script/lua_vm.zig` remains the sole Lua ABI owner. Splitting individual ABI
  calls would distribute stack invariants and dynamic-library ownership.

## Production-caller audit after the full sample

The Tidepool/Shoal-equivalent sample now exercises the integrated River shell,
window metadata, decoration lifecycle, retained composition, Skia lowering,
Wayland DMA-BUF/Vulkan presentation, configured actions, output cycling, and ordinary
`wl_pointer` bar interaction. Those host and platform layers are therefore not
speculative; they are the implementation of the supported River application.
The portable layer-shell application is also a real CLI mode, although it has
no River desktop-state or WM-action authority.

The following remain outside the production call graph and are candidates for
a clean removal pass rather than further abstraction:

- `src/runtime/lifecycle.zig`, `src/runtime/ipc.zig`, and
  `src/runtime/persistence.zig`: test-only runtime framework; the executable
  uses only argument parsing from `src/runtime/root.zig`.
- `src/host/phase.zig`: test-only sequence state machine duplicating the live
  manager/host transaction state machines.
- `src/ui/signal.zig`, `src/ui/animation.zig`, and `src/ui/target.zig`:
  test-only retained-UI experiments. Production uses `tree.zig`, `scene.zig`,
  and `properties.zig` directly.
- `src/wm/input.zig`: test-only pointer-planning vocabulary. Production input
  is lowered through script intents and the River host.
- River `pointer_binding` ownership, proxy maps, plans, and
  `src/platform/river/live/world/input.zig`: no production binding is created.
  The sample bar correctly uses standard `wl_pointer`, leaving this alternate
  input route dormant.
- `World.saveState`/`restoreState`: covered by tests but not called by the
  executable because the dormant runtime persistence layer is not wired in.
- `src/platform/river/host/transport/driver.zig`: intentionally test-only. It
  is a valuable deterministic integration seam, unlike the dormant product
  subsystems above.

The largest remaining hidden cost is `lua/whirlpool/status.lua`: its probes
are throttled, but `io.popen` is synchronous and each output owns a Lua VM, so
multi-output sessions duplicate polling and can occupy each role worker.
A single process-owned status sampler publishing service updates is the next
architectural joint if the sample becomes the production shell.

One operational mismatch is also now explicit: the installed
`whirlpool-compositor-free-smoke` script expects a source tree containing
`build.zig`, while the package installs only the launcher and helper. It works
from a checkout but not as a standalone installed command.
