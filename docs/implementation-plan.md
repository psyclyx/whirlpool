# Parallel Implementation Plan

This plan implements [`lua-architecture.md`](lua-architecture.md) as a chain of
always-green milestones. It maximizes useful parallel work without allowing
multiple workstreams to edit the same subsystem or invent competing contracts.

## Working rules

1. The module that owns a concept owns its public types. There is no generic
   `common`, `util`, or `contracts` dumping ground.
2. Cross-module dependencies point through public root modules. Platform hosts
   compose subsystems; lower layers do not reach upward.
3. Each workstream owns a disjoint directory. The integration workstream owns
   shared build files and top-level exports.
4. Until another subsystem is ready, use a fixture at the consumer boundary,
   not a compatibility shim inside the producer.
5. Every commit compiles and passes the tests relevant to the code it exposes.
6. Conventional commits stay small enough to review, revert, and bisect.
7. Performance changes report mechanism and measurements. Architectural words
   such as "retained", "Vulkan", and "dma-buf" are not performance evidence.

## Workstreams

### A. Window-management kernel

Owns:

```text
src/wm/
test/wm/
```

Produces:

- typed IDs, protocol-fact values, and authoritative policy state;
- the column/split/tab tree;
- semantic `Command` values and atomic transactions;
- pure scrolling layout and camera targets;
- `WorldSnapshot`, `ManagePlan`, and `RenderPlan`; and
- strong model tests.

This stream imports no Wayland, Lua, UI, or graphics code.

### B. Graphics and dma-buf presentation

Owns:

```text
src/graphics/
test/graphics/
```

Produces:

- Vulkan device/queue ownership;
- dma-buf feedback parsing and device/format/modifier selection;
- exportable Vulkan images and `wl_buffer` creation;
- DRM syncobj timelines and points;
- `BufferSet` lifecycle and resource retirement;
- retained Snail GPU scene updates;
- graphics counters and `GraphicsBudget`; and
- a fixed-scene presentation API usable by Studio before UI exists.

The public API accepts generic Wayland surface/commit hooks supplied by a host.
It does not import the WM or Lua.

### C. Retained UI and Lua

Owns:

```text
src/ui/
src/script/
test/ui/
test/script/
lua/
```

Produces:

- mount contexts and generation-checked retained handles;
- transactional `SceneDelta` mutations;
- native layout, signals, cells, interaction, and animation;
- the PUC Lua host and protected safe-point calls;
- snapshot/intent/node userdata;
- the program manifest and capability API;
- reusable angled primitives and current bar/decorator packages; and
- Lua/UI contract tests using fixture worlds and a fake graphics target.

This stream imports public WM value types for Lua snapshots/intents but does not
import River. Its UI core does not import Vulkan.

### D. River and host integration

Owns:

```text
src/platform/
src/host/
test/river/
test/integration/
build.zig
build.zig.zon
build.zig.zon.nix
default.nix
nix/
protocol/
```

Produces:

- dependency pins and protocol generation;
- the Wayland event loop and registry;
- River proxy maps and staged events;
- manage/render transaction enforcement;
- translation of plans into River requests;
- shell and decoration role adapters;
- Studio, Whirlpool, and surface-stress executables; and
- integration and trace tests.

This is the only stream that composes all other subsystems and edits shared
build files.

## Dependency graph

```text
                         Wave 0 contracts
                                  |
                +-----------------+-----------------+
                |                 |                 |
                v                 v                 v
          A: WM kernel      B: dma-buf core    C: retained UI
                |                 |                 |
                +---------+-------+-------+---------+
                          |               |
                          v               v
                  D: fixture hosts   C: Lua bindings
                          |               |
                          +-------+-------+
                                  v
                       end-to-end Whirlpool
```

The actual work proceeds in waves so the joins happen at explicit merge gates.

## Wave 0: freeze interfaces and dependencies

This wave is short and serial. The integration owner makes the shared edits
before the four streams diverge.

### Tasks

1. Use PUC Lua 5.4 from the npins-pinned nixpkgs revision and expose that exact
   library/header pair to the Zig build.
2. Add libdrm and the required Vulkan headers/extensions to Nix and Zig builds.
3. Generate client bindings for:
   - stable linux-dmabuf v1, version 5;
   - staging linux-drm-syncobj v1, version 1;
   - xdg-shell for Studio; and
   - the pinned River v5 protocol.
4. Establish the target directory/module layout without compatibility facades.
5. Define narrow public boundary types in their owning modules:
   - WM: IDs, snapshots, commands, `ManagePlan`, `RenderPlan`;
   - UI: `SceneDelta`, node/property identifiers, surface description;
   - graphics: `SurfaceTarget`, submitted-buffer token, commit description; and
   - platform: staged River events and surface commit hooks.
6. Replace README claims about WSI/CPU staging with the agreed architecture
   links and current implementation status.

### Merge gate 0

- `zig build test` passes.
- `nix-build` evaluates/builds with the new dependencies.
- Each public module imports independently.
- No production module is named as if it implements functionality that is
  still only a fixture.

Suggested commits:

```text
build: pin lua and dmabuf dependencies
build: generate dmabuf and syncobj protocols
refactor: establish whirlpool subsystem boundaries
```

## Wave 1: independent foundations

All four streams run in parallel after gate 0.

### A1. Real WM state and tree

- Implement generation-checked IDs and owned stores.
- Implement columns, leaves, explicit-axis splits, and tabbed containers.
- Maintain parent links and window-to-leaf indices.
- Implement insert/remove/wrap/unwrap/swap and active-child repair.
- Add invariant checks and table-driven tests.
- Add deterministic seeded mixed-operation tests.

Output: a pure tree/model library with no layout or River dependency.

Suggested commits:

```text
feat(wm): add authoritative column tree
feat(wm): apply structural commands atomically
test(wm): exercise mixed tree transitions
```

### B1. Dma-buf capability and buffer model

- Parse linux-dmabuf v5 feedback format tables and tranches.
- Match the feedback main device to Vulkan physical devices.
- Compute the explicit format/modifier intersection for XRGB8888/ARGB8888.
- Implement the pure `BufferSet`/slot state machine.
- Implement lazy second-slot allocation decisions and resize generations.
- Define FD ownership helpers with tests where possible.

The first B1 tests do not require a compositor or GPU image allocation.

Suggested commits:

```text
feat(graphics): parse dmabuf feedback
feat(graphics): select vulkan dmabuf formats
feat(graphics): model lazy surface buffers
```

### C1. Retained UI core

- Implement mount-context ownership and deterministic recursive destruction.
- Implement generation-checked node handles.
- Implement row/column/stack/spacer/shape/text node storage.
- Implement transactional `SceneDelta` apply/rollback and property coalescing.
- Implement targeted dirty propagation.
- Add a fake surface/graphics target for tests.

No Lua or text shaping is required to prove the ownership model.

Suggested commits:

```text
feat(ui): add retained mount tree
feat(ui): apply scene mutations transactionally
test(ui): cover disposal and stale handles
```

### D1. River state staging and trace host

- Replace normalized placeholder names with the real River v5 object/event
  vocabulary.
- Implement proxy maps and staged fact records.
- Complete the manage/render phase state machine.
- Translate fixture `ManagePlan`/`RenderPlan` values into ordered request traces.
- Guarantee finish requests on all handled error paths.

This stream uses fixture plans and does not wait for A1.

Suggested commits:

```text
feat(river): stage v5 protocol facts
feat(river): emit typed manage plans
test(river): trace manage and render ordering
```

### Merge gate 1

Integrate in this order: A1, C1, B1, D1, then one integration-fix commit.

- All pure tests pass under the normal allocator checks.
- The WM rejects corrupt/stale commands atomically.
- Retained UI destroys an entire mounted tree without leaks.
- Dma-buf feedback fixtures select deterministic results.
- River request traces contain no missing or out-of-phase finish request.

## Wave 2: functional vertical slices

The streams continue in parallel against the gate-1 APIs.

### A2. Scrolling layout and actions

- Port behavior, not Janet representation, from Tidepool scroll/tree code.
- Implement virtual column widths and positions.
- Implement weighted recursive split layout and tab visibility.
- Implement minimum-reveal camera targeting and clipping.
- Implement focus/swap/absorb/eject/expel/tab/resize commands.
- Implement camera and geometry animation targets as values, not clocks.
- Add focused parity cases from Tidepool tests.

Output: fixture snapshots can produce complete manage/render plans.

### B2. Real Vulkan dma-buf presentation

- Create the shared Vulkan instance/device/queue selected from dma-buf
  feedback.
- Allocate DRM-modifier external images and export their plane FDs.
- Create dma-buf `wl_buffer` objects.
- Create/import DRM syncobj timelines in Vulkan and Wayland.
- Submit a clear/fixed Snail scene, signal acquire, and consume release points.
- Implement damage and nonblocking buffer selection.
- Replace Studio's WSI presenter with one fixed dma-buf surface.

Output: `whirlpool studio` displays a fixed scene without River or WSI.

### C2. Lua and retained API

- Embed the pinned PUC Lua.
- Implement protected calls and callback budgets.
- Expose IDs and callback-lifetime read-only fixture snapshots.
- Expose intent builders against fixture WM commands.
- Expose retained node constructors, setters, mount/unmount, and watchers.
- Add the small native signal algebra and native animation targets.
- Implement Lua modules for angled section, meter, icon, and sparkline
  primitives against the fake graphics target.

Output: Lua mounts and updates a representative bar tree in headless tests.

### D2. Actual hosts and surface roles

- Implement the production Wayland dispatch/flush loop.
- Bind River manager/window/output/seat objects.
- Implement Studio xdg-shell lifecycle independently of graphics internals.
- Implement River shell/decoration role creation and destruction using fixture
  surface buffers.
- Wire surface interaction events into queued fixture actions.

Output: River host connects and completes empty/native fallback transactions;
Studio supplies a real `wl_surface` to B2.

### Merge gate 2

Integrate in this order: A2, C2, D2, B2, then integration fixes.

- Pure scrolling tests pass.
- Lua can produce validated WM commands but cannot access proxies/handles.
- Studio presents a fixed Vulkan/Snail dma-buf image and resizes cleanly.
- Vulkan validation produces no synchronization or lifetime errors.
- The River host can claim the manager role and remain responsive using native
  fallback policy with no Lua UI mounted.

Suggested milestone commit:

```text
feat: present studio through vulkan dmabuf
```

## Wave 3: real shell and scrolling WM

### A3. Window behavior completion

- Integrate window/output/seat lifecycle with the real model.
- Add tags, output usable areas, multi-output reconciliation, and scratchpad.
- Add floating placement and pointer move/resize operations.
- Add fullscreen transitions, constraints, focus repair, and borders.
- Produce decoration model snapshots and render offsets.

### B3. Retained Snail surfaces

- Replace the fixed scene with retained Snail geometry/instance records.
- Implement targeted geometry/text/image upload.
- Implement `GraphicsBudget` and resource counters.
- Support multiple independently dirty surfaces and lazy second buffers.
- Add resize retirement and surface destruction with release points in flight.
- Add `surface-stress` using simple fixture scenes.

### C3. Current bar and decorations

- Implement native text shaping/fallback and hit testing needed by the bar.
- Recreate the current angled section chain as reusable Lua controllers.
- Add workspace tags, title, scroll minimap, CPU/network sparklines, meters,
  audio/battery/clock, and native hover/pulse/scroll animation.
- Implement title/tab decoration factories from the same primitives.
- Use fixture world/system signals so the complete shell runs in Studio.

### D3. End-to-end composition

- Compose real WM snapshots/intents with the Lua safe-point phases.
- Map per-output surface factories to River shell surfaces.
- Map decoration factories to visible tiled leaves.
- Coordinate submitted dma-buf commits with River `sync_next_commit` and
  `render_finish`.
- Route decoration input to local UI state and queued WM actions.
- Add nested-River smoke scripts.

### Merge gate 3: first usable Whirlpool

Integrate A3 and B3 first, then C3, then D3. The integration owner resolves
only boundary issues; subsystem logic remains in the owning stream.

Required outcomes:

- `whirlpool studio` shows the real bar and representative decorations using
  fixture windows, with no River globals bound.
- `whirlpool` manages a nested River session with scrolling columns, splits,
  tabs, focus, floating, fullscreen, tags, and angled decorations.
- Camera/geometry/hover/pulse frames execute without Lua callbacks.
- Moving/scrolling windows does not redraw unchanged decoration buffers.
- All surface commits use dma-buf plus explicit syncobj points.
- `surface-stress -Dsurfaces=64` completes, reports honest counters, and remains
  validation-clean. This is an observation gate, not a preset performance
  threshold.

Suggested milestone commits:

```text
feat(wm): manage scrolling river windows
feat(ui): recreate the angled whirlpool bar
feat: render synchronized window decorations
```

## Wave 4: practical parity and hardening

After the first usable milestone, parallelize only features required by actual
daily use.

### A4. WM parity

- marks, summon/send, remaining tag operations;
- persistence and restart restoration;
- output configuration; and
- remaining Tidepool action parity.

### B4. Measured graphics work

- run repeated stress/current-bar measurements;
- profile CPU/GPU phases;
- change buffer counts, caching, uploads, or threading only when attributed;
- record rejected optimizations with their evidence; and
- add per-surface feedback/direct-scanout only if it serves a measured case.

### C4. Shell capabilities

- process/file/socket/timer effects used by the real bar;
- OSD, launcher, decorators, and transient surfaces;
- theme reload and explicit state save/restore where needed; and
- remaining Shoal capability parity.

### D4. Operational integration

- named-action IPC and introspection;
- robust reload and process lifecycle;
- Nix/Home Manager packaging; and
- real-session smoke scripts and documentation.

## Critical path

The critical path is intentionally short:

```text
Wave 0 contracts
  -> A1 tree
  -> A2 scrolling
  -> A3 lifecycle
  -> D3 River composition

Wave 0 protocols
  -> B1 feedback/buffers
  -> B2 real dma-buf
  -> B3 many surfaces
  -> D3 synchronized decorations
```

The Lua/UI stream is not allowed to redefine either path. It consumes WM
snapshots/intents and produces `SceneDelta` values. The integration stream is
not allowed to move policy into River callbacks or rendering into the UI.

## Review checkpoints

Pause for design review only at these joins:

1. Before gate 1: public IDs/commands/plans, `SceneDelta`, and `SurfaceTarget`.
2. Before B2 allocation: chosen DRM/Vulkan format and FD ownership table.
3. Before gate 2: syncobj point allocation/reuse rules and River commit order.
4. Before gate 3: Lua retained API as exercised by the actual bar/decorations.
5. After the first stress measurements: whether another render thread or a
   different buffer policy is justified.

Everything else should progress behind the accepted interfaces without a new
architecture round.

## Definition of done for the rewrite core

The core rewrite is complete when:

- the old placeholder model/layout/shell/presenter modules are removed rather
  than wrapped;
- Whirlpool owns the River socket and legal v5 transactions;
- the strongly tested Zig model provides the scrolling behavior used daily;
- Lua expresses configuration, current bar primitives, and decorations through
  retained handles and typed actions;
- all graphical Wayland surfaces use the shared Vulkan/dma-buf/syncobj path;
- Studio exercises the exact shell/graphics stack without River;
- normal animation/render paths contain no Lua calls, host GPU waits, full-tree
  rebuilds, or hidden per-component resource pools; and
- the test, nested smoke, Nix build, and surface-stress gates pass from a clean
  checkout.
