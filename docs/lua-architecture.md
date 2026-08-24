# Whirlpool Architecture

Status: implementation target for the first usable Whirlpool.

Whirlpool is a rewrite informed by Tidepool and Shoal. It is not a port. The
first implementation preserves Tidepool's scrolling window-management model
and Shoal's programmable shell, while changing their ownership and update
boundaries.

The corresponding dependency-aware work schedule is in
[`implementation-plan.md`](implementation-plan.md).

## Decisions

- Zig owns River, the authoritative window model, transactions, layout data,
  animation sampling, Wayland objects, Vulkan, dma-buf allocation, and Snail
  resources.
- Lua owns configuration and policy: rules, action mappings, reusable UI
  primitives, shell composition, and asynchronous data handling.
- There is no direct River/Lua API. Lua reads immutable snapshots and emits
  typed semantic intents.
- Shell UI is retained. Lua mounts native nodes once and makes transactional
  property or structural updates; rebuilding Hiccup trees is not the core API.
- The initial runtime has one event-loop thread and one Lua state. UI callbacks
  never run inside River manage/render sequences, leaving a later VM/thread
  split possible without changing the public API.
- The graphics host owns one Vulkan device and presents explicit dma-buf
  `wl_buffer` objects. Vulkan WSI swapchains are not the production surface
  backend.
- DRM syncobj timelines synchronize Vulkan and the compositor without host
  fence waits.
- Studio uses the same Lua, UI, Snail, Vulkan, dma-buf, and Wayland buffer path
  without binding River window-management globals.
- Testing is strongest around the pure window model. GPU verification stays
  deliberately lean: lifecycle tests, Studio integration, nested-River smoke,
  and a many-surface stress mode rather than a general scheduler simulator.

## Goals

The first usable Whirlpool must provide:

1. River v5 window-management ownership and legal manage/render transactions.
2. A strongly tested scrolling layout with columns, splits, tabs, focus,
   structural actions, floating windows, fullscreen, tags, and multiple
   outputs.
3. Server-side decorations using the same angled design vocabulary as the
   shell.
4. A retained Lua UI API capable of expressing the current Shoal bar as
   reusable primitives with cheap targeted updates.
5. A shared Snail/Vulkan renderer presenting many independent Wayland surfaces
   through dma-buf.
6. A Studio mode for graphics and shell iteration without acquiring a River
   socket.

## Explicitly deferred

The initial implementation does not require:

- multiple Lua states or a UI worker thread;
- custom Lua geometry layouts;
- a generic reactive programming language;
- dma-buf direct-scanout optimization;
- multi-plane or HDR buffer formats;
- a production SHM renderer;
- device-loss recovery;
- transactional UI state migration across reloads;
- multiple-seat, tablet, or touch completeness;
- fractional-scale pixel perfection beyond keeping the API scale-aware;
- a surface scheduler simulator or custom property-test shrinker; or
- exhaustive Tidepool/Shoal parity before the first usable milestone.

Deferral is not an API promise. The boundaries below must make these features
possible without exposing protocol or graphics objects to Lua.

## System boundary

```text
Wayland and River events
          |
          v
River bridge -------- owns proxies and stages protocol facts
          |
          | manage_start: immutable WorldSnapshot
          v
Zig WM kernel <------ bounded Lua policy phase
          |                     |
          | validates           | semantic intents only
          v                     v
authoritative policy state + atomic ManagePlan
          |
          v
River bridge -------- emits legal requests + manage_finish
          |
          | render_start
          v
native render planner -- camera, animation, position, clip, stacking
          |
          +----------> River requests + render_finish

asynchronous data / input
          |
          v
Lua retained UI callbacks at safe points
          |
          v
transactional SceneDelta
          |
          v
Snail/Vulkan renderer --> dma-buf wl_buffer --> Wayland surface commit
```

Protocol listeners never call Lua. River transactions never wait for Lua UI,
filesystem/process effects, text preparation, Vulkan, or the compositor.

## Initial execution model

The first implementation uses one event-loop thread. It owns:

- the Wayland display and all Wayland proxies;
- River protocol staging and transaction state;
- the Zig WM kernel;
- one PUC Lua state;
- retained UI mutation; and
- Vulkan command recording and queue submission.

GPU execution remains asynchronous. A separate render thread is not necessary
to submit work without blocking, and will not be added until measurement shows
that command preparation or submission is a meaningful event-loop cost.

Lua has two non-overlapping safe-point phases even though there is one VM:

- **WM policy phase:** bounded, non-yielding callbacks during `manage_start`.
- **Shell phase:** UI and effect callbacks between River transactions.

Shell code communicates with the WM by queuing named actions. It never calls a
WM policy callback synchronously. The host coalesces queued work into one River
`manage_dirty` request when no manage sequence is pending. This keeps the API
compatible with a future split into separate policy and shell Lua states.

## Ownership

| Concern | Owner | Lua access |
| --- | --- | --- |
| Wayland display, registry, proxies, roles, destruction | platform host | None |
| River facts and transaction phase | River bridge | Immutable snapshots |
| Tags, focus, tree, placement, marks, saved state | WM kernel | Read views; typed intents |
| Vulkan instance, device, queue, images, memory | graphics host | None |
| dma-buf FDs, modifiers, `wl_buffer`, syncobj points | dma-buf presenter | None |
| Snail pages, atlases, glyph/image cache | graphics runtime | Budget and statistics |
| Retained UI nodes, layout, text, hit testing | UI runtime | Typed handles |
| Native animation clocks and values | animation service | Targets and bindings |
| Configuration, rules, named actions | Lua | Authoritative policy |
| UI composition and package-local values | Lua | Authoritative shell policy |
| Timers, subprocesses, files, sockets | native effect services | Explicit capabilities |

No Lua userdata contains a Wayland proxy, Vulkan handle, dma-buf FD, or pointer
into a mutable Zig container.

## State domains

### Protocol facts

Facts reported by River: live objects, metadata, client requests, size hints,
actual dimensions, output geometry, seats, pointer operations, and lifecycle
events. Only the River bridge mutates these staging records.

### Desktop policy state

Whirlpool decisions: tags, focus history, ordered columns, layout trees,
floating/fullscreen placement, marks, rules already applied, camera targets,
and desired dimensions. This is typed Zig state changed only by validated
commands.

### Lua state

Configuration, module state, themes, transient UI state, and effect state. Lua
values never become the authoritative window tree. Mutable Lua globals are not
part of the supported configuration contract.

### Retained UI state

Native nodes, typed properties, signal bindings, text layout, interaction
state, and damage. This survives Lua callbacks and is disposed deterministically
with its mount context.

### Presentation state

Snail records, Vulkan images, dma-buf metadata, synchronization points, buffer
ownership, and surface generations. It is derived and can be rebuilt without
changing desktop policy.

## River and Lua

There is intentionally no River-shaped Lua API.

### Values crossing the boundary

- Window, output, seat, tree node, surface, and service identities are typed,
  generation-checked userdata.
- World and tree snapshots are read-only callback-lifetime views.
- Retaining a snapshot and using it after its callback is a stale-view error.
- Large collections use native iterators rather than copied Lua tables.
- Intent builders allocate in a host transaction arena and are discarded in
  bulk on completion or error.
- Rules, actions, layout prototypes, and views receive distinct capability
  objects; forbidden operations are absent rather than checked by convention.

### Program manifest

The exact spelling may evolve, but a minimal program has this shape:

```lua
local whirlpool = require("whirlpool")
local scrolling = require("whirlpool.layouts.scrolling") {
  column_widths = { 0.33, 0.50, 0.66, 1.00 },
  default_column_width = 0.50,
  peek = 32,
  inner_gap = 8,
  outer_gap = 8,
}

return whirlpool.program {
  api_version = 1,

  capabilities = {
    "wm.read",
    "wm.manage",
    "shell.surface",
    "process.spawn",
  },

  layout = scrolling,
  bindings = require("config.bindings")(scrolling),
  rules = require("config.rules"),

  surfaces = {
    bar = whirlpool.surface.per_output(require("config.bar")),
  },

  decorations = require("config.decorations"),
}
```

Packages declare an API version and capabilities. The host grants capabilities
by callback kind; a view never receives an intent or effect builder.

### Rules

Rules receive immutable initial window facts and return a partial disposition:
tags, output preference, tiled/floating, initial placement, decoration mode,
and capabilities. Results merge in declaration order. Rules cannot perform I/O
or mutate the tree.

### Actions and intents

Bindings, UI controls, and IPC share named semantic actions. Actions inspect a
world snapshot and emit typed intents such as:

- focus a window, direction, output, or history entry;
- view/toggle/send tags and scratchpad;
- move, swap, wrap, absorb, eject, or expel tree nodes;
- resize a column or split weight;
- select a container mode or active tab;
- toggle floating, fullscreen, maximized, or minimized state;
- move/resize/center a floating window;
- start/end a pointer operation;
- close a window, set a mark, or select a layout; and
- exit, restart, or reload Whirlpool.

Intents describe policy and never mirror River requests. The kernel validates
the whole batch and applies it atomically.

### Effects

Effects run outside River transactions:

- dispatch a message or named action;
- one-shot/repeating timer;
- spawn a process;
- managed Unix socket or stream;
- asynchronous file read/watch;
- logging and persistent namespaced values; and
- create, destroy, or message a shell surface.

Services have stable IDs and explicit cancellation. Property updates may
coalesce last-value-wins; input and completion events are ordered and bounded.
Overflow is reported rather than silently dropping non-coalescible events.

## River transaction contract

### Incoming staging

Window/output/seat events update Zig staging records and enqueue normalized
notifications. They do not run policy immediately.

### Manage sequence

At `manage_start`, Whirlpool:

1. freezes a `WorldSnapshot` containing the complete staged change set;
2. performs mandatory lifecycle reconciliation in Zig;
3. enters one bounded Lua policy phase for new-window rules and queued actions;
4. validates and atomically applies the resulting intent batches;
5. evaluates native layouts for dirty tags;
6. builds a `ManagePlan`;
7. emits legal dimension/state/focus/binding requests; and
8. sends `manage_finish`, including on policy failure.

Callbacks in the phase observe the same desktop snapshot. A failed callback
publishes no intents. A minimal native policy keeps the protocol responsive if
Lua fails.

### Render sequence

At `render_start`, Whirlpool:

1. consumes actual window dimensions reported by River;
2. samples native camera/window animations;
3. derives positions, clips, visibility, stacking, borders, and decoration
   offsets;
4. commits any already-submitted decoration/shell buffers that must be atomic
   with this render transaction;
5. emits River rendering requests; and
6. sends `render_finish` without host waits.

Lua is never called in this sequence. Missing or busy surface buffers retain
their previous content; Whirlpool does not wait for them.

## Authoritative window model

Each tag owns an ordered forest of columns:

```text
Tag
  columns: [Column]
  focused_leaf: ?NodeId
  camera_target: f32

Column
  id: NodeId
  width: f32
  root: NodeId

Node
  leaf(window_id)
  split(axis, weighted children)
  tabbed(active child, children)
```

Nodes have stable generation-checked IDs. Parent links and window-to-leaf
indices are maintained by the kernel, not reconstructed by Lua.

The kernel owns invariants including:

- each tiled window has exactly one leaf in its owning tag;
- every non-empty column has one valid root;
- parent/child links are reciprocal and acyclic;
- weights and column widths are finite and within configured limits;
- a tabbed container has a valid active child;
- focus points to a live, visible candidate or is empty;
- inactive tab descendants retain target geometry but are not presented; and
- removing an output/window repairs ownership and focus deterministically.

### Scrolling layout

The built-in scrolling layout is native Zig and pure over a model snapshot.

1. Convert column width ratios to pixel widths in a virtual horizontal strip.
2. Recursively lay out each column's split/tab tree.
3. Select a camera target using minimum movement that reveals the focused
   column plus the configured neighboring peek.
4. Propose window content dimensions during the manage sequence.
5. During render, derive `screen_x = virtual_x - sampled_camera + output_x`.
6. Clip each visible window to the output usable area.

Horizontal scrolling animates one camera scalar per tag, not one independent x
animation per window. Lua does not run per animation frame.

The native action set includes directional focus/swap, absorb, eject, expel,
column-width cycling, split-weight resizing, tab activation, and split/tab mode
changes. Lua configures bindings and parameters around those operations.

### Floating and fullscreen

Floating placement is authoritative Zig policy state. A floated window can be
anchored to an output or to the scrolling virtual strip according to the
selected action. Interactive resize/move consumes cumulative River pointer-op
deltas and emits one validated command per manage sequence.

Fullscreen temporarily overrides normal placement and clipping without
destroying the underlying tree location. Exiting fullscreen restores layout
ownership and forces fresh dimension proposals.

## Retained Lua UI

Shoal's composability remains, but a Lua primitive mounts native nodes once
instead of returning a fresh Hiccup value on every update.

```lua
function widgets.section(parent, opts, mount_contents)
  local root = parent:row {
    height = opts.height or 38,
    gap = opts.gap or 8,
    padding = opts.padding or { 0, 12, 0, 2 },
    background = {
      shape = widgets.angled_quad,
      color = opts.color,
    },
  }

  local controller = mount_contents(root) or {}
  controller.root = root
  return controller
end
```

Reusable Lua primitives return controllers holding retained handles. They may
compose rows, columns, shapes, text, meters, sparklines, icons, and other Lua
primitives without creating a new native abstraction for each widget.

### Mount lifetime

- A `MountContext` owns every node, watcher, cell, handler, timer, and child
  context created through it.
- Destroying a context deterministically destroys its descendants and cancels
  its services.
- Children cannot outlive their parent unless moved through an explicit future
  transfer API; transfer is not in the first implementation.
- Handles are generation checked. Use after unmount is a normal Lua error.
- Reparenting is not supported initially. Keyed list updates insert/remove
  native children under a fixed parent.

### Native node vocabulary

- layout: row, column, stack, scroll, spacer;
- content: text, shape, image, fixed-capacity instance series;
- behavior: clip, input region, scroll region;
- style: fill, border, radius, shadow, opacity, transform; and
- interaction: hover/pressed/focused state and pointer handlers.

Text shaping, fallback, measurement, line breaking, hit testing, and drawing
stay native.

### Signals, cells, and watches

Common hot updates avoid Lua entirely:

```lua
title:bind_text(ctx.world:signal("focused_title"))
tab:bind_color(ui.choose(child:signal("active"), active, inactive))
clock:bind_text(ctx.clock:format("%H:%M"))
```

The initial native signal algebra stays small: direct bindings, boolean
inversion, choice, simple numeric transforms, and colors. A general reactive
graph is deferred.

Custom work uses a watcher:

```lua
ctx:watch(ctx.system.memory, function(value)
  meter:set(value.percent)
end)
```

The host opens one scene transaction around each delivered callback batch.
Setters append compact mutations. On callback failure, the mutations are
discarded and the last good scene remains live. Multiple writes to the same
property in a batch coalesce to the final value.

Native cells provide observable UI-local values when required. Plain Lua
locals are appropriate for immutable configuration, not frame-driven state.

### Performance contract

- No Lua call is required for native animation frames.
- An unchanged surface performs no layout, upload, submission, or commit.
- Updating one non-geometric property does not walk the whole tree.
- Shared shapes such as angled rectangles use one cached geometry record and
  per-instance transforms/colors.
- Sparklines use fixed native instance storage rather than one Lua node per
  sample.
- Structural lists are keyed and update only inserted/removed/moved children.
- Costs are visible through counters: callbacks, nodes touched, layout work,
  text shaping, geometry rebuilds, upload bytes, submissions, and commits.

## Surfaces

`whirlpool-ui` is host independent. A host supplies surface size/scale, input,
a graphics target, a clock, an event sink, and a platform adapter.

The River host maps UI surfaces to `river_shell_surface_v1` or
`river_decoration_v1`. Studio maps them to xdg-shell. Both use the same retained
tree and dma-buf presenter.

Surface kinds include per-output panels, overlays/OSDs, transient launchers,
offscreen test targets, and window decorations. Creating a surface is explicit
and potentially expensive; mutating a retained node is cheap.

Pointer hover and press visuals may update native UI state immediately. Any
operation that changes WM state queues a named action and is applied during the
next manage sequence. Keyboard focus for a shell surface is likewise a River
intent, not an immediate Wayland-side mutation.

## Dma-buf presentation

### Required protocols and Vulkan capabilities

The graphical runtime uses:

- `zwp_linux_dmabuf_v1` version 5 feedback and buffer creation;
- `wp_linux_drm_syncobj_manager_v1` version 1 explicit synchronization;
- Vulkan external-memory FD and dma-buf support;
- Vulkan DRM format modifiers;
- Vulkan timeline semaphores/external semaphore FDs; and
- libdrm syncobj support.

The pinned River revision advertises linux-dmabuf v5 when its renderer supports
dma-buf textures and advertises DRM syncobj when the renderer/backend provide
timeline support and a DRM FD.

Production graphical Whirlpool requires dma-buf and DRM syncobj. Headless
deterministic tests may use Snail's CPU renderer. A production SHM renderer and
implicit-synchronization path are not part of the first implementation.

### Device and format selection

At startup, the presenter:

1. receives default dma-buf feedback;
2. identifies the compositor main DRM device;
3. selects a matching Vulkan physical device;
4. intersects feedback format/modifier pairs with Vulkan external render-target
   support; and
5. selects a single-plane initial format.

The first implementation supports `XRGB8888` for opaque surfaces and
`ARGB8888` with premultiplied alpha for translucent surfaces. It records the
selected DRM format, Vulkan format, modifier, planes, offsets, and strides
explicitly. Direct-scanout tranches and per-surface feedback optimization are
deferred.

If no compatible device/format/modifier exists, startup fails with the complete
capability intersection rather than silently choosing a CPU path.

### Buffer creation

For each buffer slot, the presenter:

1. creates a DRM-modifier Vulkan image with external dma-buf memory;
2. allocates and binds exportable memory;
3. obtains plane layout and dma-buf FDs;
4. creates a `zwp_linux_buffer_params_v1` with explicit plane metadata;
5. creates the corresponding `wl_buffer`; and
6. creates/imports synchronization timelines shared by Vulkan and Wayland.

FD ownership is explicit. Export duplicates and Wayland-transferred FDs are
closed at the boundary defined by their APIs; the underlying allocation stays
alive for the complete `wl_buffer` lifetime.

### Lazy buffer set

Each live surface owns a `BufferSet`:

```text
slot A: allocated on first render
slot B: allocated only when A is unavailable and the surface is dirty
pending scene generation: latest value only
```

A static surface therefore normally consumes one image. A second image is
created lazily under contention, subject to the global graphics budget. If both
slots are busy, further property changes coalesce into the pending generation.
The surface retains its prior committed content until a slot becomes available.

Each slot moves through explicit states:

```text
available -> recording -> submitted -> committed -> release_pending -> available
                                      \-> retired_pending -----------> destroyed
```

Resize creates a new `BufferSet` generation. An old slot that is no longer in
use is destroyed immediately; an old submitted or committed slot becomes
`retired_pending` and is destroyed only after its Vulkan work and compositor
release point have completed. Retired slots never re-enter the available set.

### Explicit synchronization

Whirlpool uses DRM syncobj timelines imported into Vulkan and Wayland:

- a monotonically increasing render timeline supplies acquire points signaled
  by Vulkan submissions; and
- each buffer has its own release timeline signaled by the compositor.

Before rendering into a reused slot, Vulkan waits for that slot's previous
release point. The render submission signals a new acquire point. At commit,
Whirlpool supplies that acquire point and a new release point to the surface's
syncobj object.

Release timelines are per buffer because compositor releases may arrive out of
commit order. While explicit synchronization is active, buffer reuse relies on
release points rather than `wl_buffer.release`.

The normal path performs no host fence wait, queue idle, or device idle.

### Commit ordering

Surface content can be prepared and submitted before River's render sequence.
When a submitted buffer must be committed atomically with River state,
Whirlpool performs, in protocol order:

1. the River role's `sync_next_commit` request;
2. `wl_surface.attach` with the dma-buf `wl_buffer`;
3. acquire and release point requests on the syncobj surface object;
4. buffer-coordinate damage;
5. `wl_surface.commit`; and
6. `river_window_manager_v1.render_finish` after all River render requests.

If there is no submitted buffer, Whirlpool sends none of steps 1--5 and keeps
the old surface content. It never promises a synchronized commit it cannot
make.

Studio and shell updates that do not require River atomicity use the same
buffer lifecycle with ordinary Wayland commits and frame-callback pacing.

## Decorations

The River host owns decoration role objects, offsets, input regions, surface
commits, and destruction. Lua owns only retained contents and interactions.

The first implementation creates one decoration band for each visible tiled
leaf that supports server-side decoration. Floating/fullscreen/inactive-tab
windows do not keep a live presented decoration surface.

For a leaf inside a tabbed container, the band represents the nearest tabbed
ancestor. It shows one angled tab per child and is attached to the active
window. More elaborate nested-tab breadcrumbs are deferred.

Decoration contents use the same Lua primitives as the bar:

```lua
return whirlpool.decoration_factory {
  height = 28,

  mount = function(ctx)
    local root = ctx.surface:stack { height = 28 }
    local title = mount_title(root, ctx.node)
    local tabs = mount_tabs(root, ctx.node)

    title:bind_visible(ctx.node:signal("tabbed"):not_())
    tabs:bind_visible(ctx.node:signal("tabbed"))
    root:on_drag(whirlpool.wm.pointer.begin_move(ctx.window:id()))
    return root
  end,
}
```

Moving or scrolling a window changes its River position/clip and decoration
offset; it does not redraw decoration pixels. Title/focus/tab/theme/width
changes dirty only the affected decoration. Hover and color animations remain
native and do not invoke Lua per frame.

## Resource budgets and backpressure

The graphics runtime owns one explicit `GraphicsBudget`. It covers:

- total resident dma-buf bytes and buffer slots;
- Snail logical pages and per-page curve/band capacity;
- glyph/image/geometry cache residency;
- transient instance and batch capacity;
- staging/upload bytes; and
- retired resources waiting for GPU/compositor release.

No scene, component, or surface chooses hidden pool sizes.

On pressure, Whirlpool coalesces superseded scene mutations, leaves a static
surface on its last good buffer, evicts rebuildable cache entries, and reports
the condition. It does not silently discard ordered input/effect events or
violate a River transaction to produce fresher pixels.

The first implementation does not invent automatic tuning thresholds. Budget
defaults are derived from configured limits and measured workloads, exposed in
Studio, and overrideable in tests.

## Failure and reload

- A failed WM callback discards its intent arena and uses native fallback
  policy while still completing the River sequence.
- A failed UI callback discards its `SceneDelta` and retains the last good
  native scene.
- A failed effect produces an error message to its owner.
- A failed dma-buf allocation or render retains the last committed buffer and
  reports a structured graphics error.
- Startup fails clearly if required dma-buf/syncobj/Vulkan capabilities are
  missing.
- A candidate Lua VM is loaded and manifest-validated before replacing the
  current VM. A failed candidate leaves the current configuration running.
- UI state migration is not automatic initially. Reload remounts UI while the
  authoritative Zig window model survives.
- Persistent desktop state uses a versioned Zig schema. Lua may own a
  namespaced serializable payload but does not define the kernel file format.

## Lean verification and measurement

### Required correctness tests

1. Pure WM tests cover every tree command, lifecycle transition, tag/output
   invariant, focus successor, constraint, and scrolling geometry rule.
2. Deterministic seeded mixed-operation tests check all invariants after every
   transition. A custom shrinker is not required.
3. Invalid intent batches prove byte-equivalent serialized policy state before
   and after rejection.
4. River trace tests assert representative ordered request sequences and that
   every started manage/render sequence finishes.
5. Lua contract tests run actions/rules against fake snapshots without a
   Wayland socket.
6. Retained UI tests cover mount, targeted mutation, keyed insertion/removal,
   deterministic unmount, and stale handles.
7. Dma-buf unit tests cover buffer state transitions, lazy second-slot
   allocation, resize retirement, and destruction after release.
8. Studio renders representative bar and decoration fixtures through the real
   Vulkan/dma-buf path.
9. A nested-River smoke test covers role creation, synchronized commits,
   scrolling, resize, and destruction with buffers in flight.

### Stress mode

`surface-stress` creates a configurable number of independently dirty surfaces
and reports:

- live surfaces, buffers, and resident bytes;
- Lua callbacks and allocations;
- nodes/properties touched;
- text/geometry preparation;
- upload bytes;
- submissions and surface commits;
- busy-buffer skips; and
- CPU update/submit latency.

The stress mode is a measurement tool, not a simulated compositor or a source
of performance claims by itself. Optimization work starts from repeated
measurements of the real path.

### Deferred verification

The first milestone does not build a general surface scheduler simulator,
adversarial GPU completion framework, device-loss harness, custom trace
shrinker, or exhaustive visual golden suite.

## Module layout

```text
src/
  wm/
    world.zig           protocol facts + authoritative policy state
    command.zig         semantic command union
    transaction.zig     validation + atomic application
    tree.zig            column/split/tab forest
    scroll.zig          pure scrolling geometry + camera target
    actions.zig         native semantic operations
    persist.zig         versioned state codec

  platform/river/
    host.zig            display, registry, event loop
    objects.zig         proxy maps + staged facts
    manage.zig          ManagePlan -> River requests
    render.zig          RenderPlan + surface commits -> River requests

  script/
    lua.zig             VM ownership + protected safe-point calls
    values.zig          snapshot/ID/builder userdata
    program.zig         manifest, rules, actions, surface factories
    effects.zig         capability service dispatcher

  ui/
    runtime.zig         mount contexts + retained nodes
    mutation.zig        transactional SceneDelta
    signal.zig          small typed native signal algebra
    layout.zig          retained UI layout
    text.zig            shaping/fallback/cache
    input.zig           hit testing + native interaction state
    animation.zig       native timelines/springs

  graphics/
    runtime.zig         shared device, GraphicsBudget, scheduling
    scene.zig           retained Snail records + targeted updates
    vulkan.zig          Vulkan device and renderer
    dmabuf.zig          feedback, formats, exported images, wl_buffers
    syncobj.zig         shared timelines and point allocation
    surface.zig         BufferSet lifecycle and commits

  host/
    whirlpool.zig       composes WM + Lua + UI + graphics + River
    studio.zig          composes Lua + UI + graphics + fixture world
    surface_stress.zig  many-surface measurement workload
```

Dependencies point inward through public module APIs. The WM never imports UI,
graphics, Lua, or Wayland. UI never imports River or Vulkan. Graphics never
imports the WM or Lua. Platform hosts compose them.

## Capability migration checklist

### Tidepool

- River v5 window/output/seat lifecycle and manage/render transactions;
- output usable areas and output configuration;
- tags, scratchpad, and multi-output reconciliation;
- scroll columns, splits, tabs, camera, and clipping;
- focus/swap/absorb/eject/expel/resizing/marks;
- floating/pointer operations, constraints/rules, fullscreen;
- bindings, cursor policy, borders, decorations, and animation; and
- persistence, IPC/action introspection, signals, restart/exit.

### Shoal

- retained component controllers, native cells/signals, watchers, and effects;
- dynamic/per-output/transient/offscreen surfaces;
- layout, theme/style primitives, reusable angled widgets;
- text shaping, fallback, measurement, and caching;
- native animation and targeted damage;
- pointer/keyboard hit testing and messages;
- timer/process/file/socket data sources; and
- the current bar, OSDs, decorators, and Studio fixtures.

This checklist tracks migration scope. It does not require every item before
the first end-to-end scrolling/decorations milestone.

## Protocol reference baseline

- [linux-dmabuf v1](https://wayland.app/protocols/linux-dmabuf-v1), including
  version 5 feedback;
- [linux-drm-syncobj v1](https://wayland.app/protocols/linux-drm-syncobj-v1),
  including acquire and release timeline points;
- [Vulkan external dma-buf memory](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_external_memory_dma_buf.html);
- [Vulkan DRM format modifiers](https://registry.khronos.org/VulkanSC/specs/1.0-extensions/man/html/VK_EXT_image_drm_format_modifier.html); and
- the River v5 protocol XML pinned in `npins/sources.json` and vendored under
  `protocol/`.
