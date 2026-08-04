# Whirlpool Zig/Lua Architecture

Status: proposed. This document defines the boundary to agree on before the
Tidepool and Shoal rewrites continue.

## Goal

Whirlpool is one process with three separately testable parts:

1. A Zig window-management kernel that owns River, authoritative desktop
   state, transactions, and invariants.
2. A reusable Zig UI runtime that owns shell surfaces, layout, text, input,
   animation, and Snail resources, but not the process graphics context.
3. A Lua policy and composition layer that configures the window manager,
   defines actions/rules/layouts, and composes shell components.

This retains Tidepool's programmability and Shoal's declarative composition
without putting protocol objects, rendering resources, or one giant mutable
database in the scripting runtime.

## The boundary

There is intentionally no direct River/Lua API.

```text
River callbacks
    |
    v
Zig River bridge -- stages facts and owns every proxy
    |
    | one immutable snapshot at manage_start
    v
Zig WM kernel <----> one bounded Lua policy phase
    |                  |
    | validates        | returns intents, never protocol requests
    v                  v
atomic manage plan + typed effects
    |
    v
Zig River bridge -- emits legal v5 requests and manage_finish
    |
    v
Zig render planner -- dimensions, animation, position, clip, stacking
    |
    v
River render_finish / Whirlpool Vulkan renderer
```

Protocol listeners do not call Lua. They only update staging records and enqueue
events. Lua runs at explicit safe points in the host event loop.

## Ownership

| Concern | Owner | Lua access |
| --- | --- | --- |
| Wayland display, registry, proxies, object destruction | River bridge | None |
| Vulkan instance/device/queue/swapchains | graphics host | None |
| Snail page pool, atlases, upload cache | graphics runtime | Budget and stats only |
| Window/output/seat protocol facts | WM kernel | Read-only snapshot |
| Tags, focus, placement, marks, layout trees | WM kernel | Read snapshot; submit intents |
| River manage/render phase | River bridge | Callback context implies phase |
| Window geometry constraints and committed dimensions | WM kernel | Read-only facts |
| Animation clocks and interpolated render state | native animation service | Declarative targets |
| Shell surface lifecycle | UI runtime + host adapter | Declarative surface specs |
| UI scene tree, layout, text shaping, hit testing | UI runtime | Construct keyed nodes |
| Configuration, rules, action mapping | Lua | Authoritative policy |
| Component-local state | Lua program | Returned serializable values |
| Timers, subprocesses, files, sockets | native effect services | Explicit capabilities |

The kernel never retains a borrowed Lua table as authoritative desktop state.
Lua never retains a pointer into a kernel container.

## State strata

Whirlpool keeps four kinds of state distinct:

### Protocol facts

What River has reported: live objects, window metadata, dimension hints,
committed dimensions, output geometry, seats, pointer operations, and pending
close/remove events. Only the River bridge mutates these records.

### Desktop policy state

What Whirlpool has decided: tag ownership, focus history, floating/fullscreen
placement, per-tag layout trees and parameters, marks, rules already applied,
and desired geometry. This is typed Zig state changed only by validated intents.

### Lua program state

Configuration and component-local values that have no protocol invariant: a
selected theme, OSD visibility, module counters, user preferences, and similar
data. Callback state is represented by a host-owned, serializable value tree. A
callback receives a read-only view and returns its replacement. The host
publishes that replacement only after the callback and its intent batch both
succeed, so an exception cannot leave partially mutated program state behind.
Mutating module globals is unsupported.

### Render state

Interpolated positions, clips, stacking, shaped text, retained UI nodes, Snail
records, atlas residency, and per-surface damage. This is derived and can be
rebuilt without changing desktop policy.

## Lua program model

Use a small program/component model, not a global re-frame database and dynamic
coeffect/effect registries.

A Lua package returns a manifest:

```lua
return whirlpool.program {
  initial_state = {},

  actions = {
    ["focus-left"] = function(ctx, args) ... end,
    ["send-to-tag"] = function(ctx, args) ... end,
  },

  rules = {
    function(window) ... end,
  },

  layouts = {
    scroll = function(ctx, tree, out) ... end,
  },

  surfaces = {
    bar = whirlpool.surface(spec, bar_component),
  },
}
```

The exact Lua spelling is not frozen by this example. The semantic contracts
below are.

Every package declares an API version and requested capabilities. The host
grants capabilities by package and callback kind: a bar component can read tag
state and dispatch a named action without automatically gaining process or file
access. The Zig tagged unions that implement snapshots, intents, effects, and
subscriptions are also the source of generated Lua API documentation and
runtime introspection.

### Actions

An action has the semantic shape:

```text
action(program_state, world, args, out) -> new_program_state
```

It receives read-only program state and world views plus an intent/effect
builder. It may request semantic changes such as focus, move, resize, tag, tree
edit, close, spawn, or surface messages. It does not mutate either input.

Actions are invoked by key/pointer bindings, IPC, shell interaction, or another
Lua message. Their result is validated and applied as one batch. A successful
batch requests a River manage transaction when necessary.

### Rules

Rules receive immutable initial window facts and return a partial disposition:
tag, output preference, tiled/floating, initial size/position, decoration mode,
and capabilities. Rule results merge in declaration order and are applied once
as part of window adoption. A rule cannot perform I/O.

### Layouts

The kernel owns a generic per-tag forest made from leaf, split, and tabbed
nodes. Nodes carry weights and stable IDs; top-level nodes may also carry scroll
column width. Lua may:

- select a built-in layout (`scroll`, `master-stack`, `grid`, `dwindle`, or
  `tabbed`);
- submit tree-edit intents used by focus/swap/absorb/eject/tab actions; or
- register a custom geometry function over a read-only tree snapshot.

A custom layout returns placements through an arena-backed builder. The kernel
rejects duplicate/unknown windows, invalid dimensions, illegal fullscreen
plans, and plans that omit a window without explicitly hiding it. Scroll
layouts may place windows outside the output and provide a clip/camera plan.

This preserves programmable layout policy without making Lua's tables the
window model.

### Components

Shell components use an Elm-like local contract:

```text
init(props) -> state, effects
update(state, message, context) -> new_state, effects
view(state, context, ui) -> node
subscriptions(state, context) -> descriptors
```

There is no process-global `db`, implicit coeffect injection, or map of
arbitrary effect keywords. Components communicate with messages. The host
provides a fixed set of typed effect and subscription capabilities.

### Why this is not re-frame

Shoal's re-frame layer made all state globally addressable and made behavior
extensible by registering names in several dynamic registries. That is useful
for experimentation, but obscures ownership and turns misspellings and wrong
payload shapes into runtime behavior.

Whirlpool instead has one typed owner for each state domain, direct component
message routing, fixed native capability unions, and package-local extension
points. A shared application model can be built as an ordinary parent
component or message service; it is not privileged infrastructure.

## Callback capability matrix

| Callback | May read | May produce | Forbidden |
| --- | --- | --- | --- |
| rule | initial window/output facts | partial disposition | effects, tree mutation, protocol access |
| action | program state + world snapshot | program state, WM intents, deferred effects | direct I/O or protocol access |
| layout | tree/output snapshot | placement + camera plan | effects, policy mutation |
| component update | local state + message + subscribed context | local state, messages, deferred effects | WM mutation except dispatching a granted action |
| component view | local state + subscribed context | keyed native UI tree | effects and mutation |
| subscription | local state + context | typed descriptors | starting services directly |

The matrix is enforced by distinct userdata/metatables, not by convention. A
layout callback is never handed an effect builder, and a view callback is never
handed an intent builder.

## Values crossing the boundary

- Window, output, seat, node, surface, timer, and connection IDs are typed
  userdata backed by generation-checked handles. They are not lightuserdata or
  floating-point numbers.
- Snapshots are read-only userdata views valid only for the callback. Retaining
  one and using it later is an explicit stale-handle error.
- Small records are exposed by named accessors. Large collections use native
  iterators rather than copying the world into Lua tables.
- Strings are immutable callback-lifetime views unless Lua explicitly copies
  them.
- Intent, UI, and effect builders allocate from host-owned frame/transaction
  arenas. The cost is visible at the API entry point and reclaimed in bulk.
- Lua callbacks and userdata never contain Wayland proxy or Vulkan addresses.

## River transaction contract

### Incoming staging

`window`, `output`, `seat`, and their object events update Zig staging records.
They may enqueue normalized notifications, but do not immediately run policy.

### Manage sequence

At `manage_start` Whirlpool:

1. freezes a `WorldSnapshot` containing the complete staged change set;
2. applies mandatory lifecycle reconciliation in Zig;
3. enters one bounded Lua policy phase, invoking the applicable rules and
   queued actions in deterministic order against the same snapshot;
4. collects their replacement program state, intents, and deferred effects;
5. validates and atomically applies their intent batches;
6. evaluates native or Lua layout policy for dirty tags;
7. builds a typed `ManagePlan`;
8. emits dimension/fullscreen/visibility/focus/border/binding requests; and
9. sends `manage_finish` even if Lua failed.

There is one VM entry phase per manage sequence, not one entry per River event.
That phase may make several protected Lua calls (for example, one rule per new
window followed by queued actions), but none can observe another callback's
desktop-state intents until the whole batch is validated and committed. Program
state reductions are ordered and feed the next action in the phase, but the
host publishes only the final value after the complete batch succeeds.

### Render sequence

At `render_start`, Zig consumes actual window dimensions, advances native
animations, computes position/clip/stacking/decorations, emits render requests,
and sends `render_finish`.

Lua is not on River's `render_start`/`render_finish` path. This avoids VM
latency and GC jitter in a protocol sequence that exists for frame-perfect
window presentation. A layout change produced by Lua marks native state dirty
and is reflected by the next native render plan.

Shell UI is a separate frame domain. Component `update` and `view` callbacks
may run at a UI safe point when subscribed state changes, but the resulting
native tree is retained. Vulkan frame submission, animation sampling, text
drawing, and damage-only redraws do not call Lua unless the component itself
has been invalidated.

## Capability surface

### Read-only world queries

- Outputs: identity, name/description, position, dimensions, scale/transform,
  usable area, active/primary tags, capture/presentation facts.
- Windows: identity, app ID/title, parent, lifecycle, PID/identifier,
  constraints, dimensions, requested states, decoration hint, tags, placement,
  urgency, tree path, focus and presentation history.
- Seats: identity, focused output/window, pointer focus/position, active
  operation, session lock state.
- Policy: per-tag tree, selected layout and parameters, marks, saved placement,
  pending animation targets.
- Shell: surface instances, output association, size, focus/hover state.

### Window-management intents

- focus window/output/direction/history;
- set/toggle/focus/send tags and scratchpad;
- insert/remove/move/swap/wrap tree nodes;
- absorb/eject/expel, change active tab, and resize weights/columns;
- set tiled/floating/fullscreen/maximized/minimized disposition;
- move/resize/center/gather floating windows;
- close a window and start/end pointer operations;
- set marks and summon/send marked windows;
- select layout and adjust its parameters;
- configure bindings, cursor preferences, borders, and decoration policy;
- request output configuration through a separate privileged service; and
- request session exit/restart.

Intents describe policy. They do not mirror River request names.

### Effects outside River transactions

- dispatch messages/actions;
- one-shot and repeating timers;
- spawn a process or execute a command;
- managed Unix-socket/stream connections;
- asynchronous file reads and file watches;
- write stdout/log messages;
- save/load named persistent values;
- create/destroy/message shell surfaces;
- request a render or offscreen render; and
- request a transactional Lua reload.

Every service has a stable ID, explicit cancellation, bounded queues, and a
completion/error message. Effects never run synchronously inside `manage`.

## UI declarations: beyond Hiccup

Shoal's Hiccup tree is close in spirit but relies on magic positional tables,
global subscription state, and a full dynamic-tree decode every frame.

Whirlpool uses typed Lua constructors that create native, arena-backed nodes:

```lua
return ui.row {
  key = "bar",
  gap = theme.space_2,
  children = {
    ui.text { key = "tags", text = model.tags, style = styles.tags },
    ui.spacer { grow = 1 },
    ui.text { key = "clock", text = model.clock, style = styles.clock },
  },
}
```

The initial node vocabulary is deliberately small:

- layout: row, column, stack, scroll, spacer;
- content: text, path, image;
- behavior: clip, input region, scroll region;
- decoration expressed as style on any node: fill, border, radius, shadow.

Constructors validate names and types immediately and return opaque node
handles, not tables for a later generic walker. Stable keys allow the native
runtime to retain animation, text, and interaction state across view calls.
Repeated interactive/stateful nodes require keys.

Text shaping, fallback, measurement, line breaking, hit testing, pointer state,
and drawing stay native. Lua receives element messages containing a key, event
kind, button/modifiers, and local coordinates.

## Subscriptions and invalidation

Subscriptions are declarative component descriptors rather than arbitrary
global functions:

- world domains (`windows`, `focus`, `tags`, `outputs`, `theme`);
- timer/clock;
- process output;
- socket messages;
- file changes; and
- host/user signals.

The host diffs descriptors by stable key and owns their lifecycle. World
snapshots expose generation counters by domain. A surface rerenders when a
domain it read changed, its component state changed, an animation is active, or
it was explicitly invalidated. No deep comparison of a global Lua database is
required.

## Surfaces and graphics

`whirlpool-ui` is a library. It does not connect to Wayland or create a Vulkan
instance. A host gives it:

- surface extent/scale and input state;
- a graphics runtime and frame target;
- a clock and event sink; and
- a platform surface adapter.

The River host maps declarations to `river_shell_surface_v1`; Studio maps them
to ordinary xdg-shell windows. Both use the same component, layout, text, input,
animation, and Snail code.

The graphics runtime, not a scene or component, owns an explicit
`GraphicsBudget`: Snail logical pages and per-page curve/band capacity, image
capacity, transient instance/batch capacity, and upload/staging limits. It
publishes pool statistics, has a defined compaction/rebuild policy for
`OutOfLayers`, and can be configured in tests. A component cannot silently
change the residency budget.

## Lua runtime policy

Prefer PUC Lua with 64-bit integer support and no FFI. The exact version is a
dependency decision after this architecture is accepted.

The default environment includes base language, table, string, math, utf8, and
a Whirlpool-controlled module loader. It excludes raw filesystem/process APIs,
`debug`, and native module loading. Equivalent work goes through effects so it
cannot block a River transaction. An explicitly unsafe development capability
may be added later, but is not part of the configuration contract.

Callbacks have an instruction/time budget. The normal manage callback target
is a small fraction of one frame; the hard deadline must stay well below
River's unresponsive-client timeout.

## Failure and reload semantics

- Intent builders are discarded on callback error; partially emitted protocol
  requests are impossible.
- A manage failure uses a minimal native fallback plan and still sends
  `manage_finish`.
- A UI failure retains the last good native scene; Studio may additionally show
  an error overlay.
- An effect failure becomes a component/action message.
- Queue overflow is a reported error, never silent dropping.
- Reload builds and validates a second Lua VM. It may receive serialized program
  state through explicit `save`/`restore` hooks. The host swaps VMs only between
  protocol transactions; a failed candidate leaves the old VM running.
- Persistent desktop state uses a versioned Zig schema. Lua may add a namespaced
  serializable payload but does not define the kernel file format.

## Module layout

```text
src/
  wm/
    world.zig          protocol facts + authoritative policy state
    transaction.zig    intent validation and atomic application
    tree.zig           layout forest and structural operations
    layout/            built-in geometry policies
    actions.zig        semantic native operations
    persist.zig        versioned state codec
  platform/river/
    host.zig           display, registry, event loop
    objects.zig        proxy maps and staged facts
    manage.zig         ManagePlan -> River requests
    render.zig         RenderPlan -> River requests
  script/
    lua.zig            VM ownership and protected calls
    values.zig         snapshot/ID/builder userdata
    program.zig        manifest, action/rule/layout/component callbacks
    effects.zig        capability service dispatcher
  ui/
    runtime.zig        surfaces, components, invalidation
    tree.zig           keyed native view tree
    layout.zig         native UI layout
    text.zig           shaping/fallback/cache
    input.zig          hit testing and messages
    animation.zig      native timelines/springs
  graphics/
    runtime.zig        GraphicsBudget, Snail pools/atlases/cache
    vulkan/            native Snail Vulkan backend and frame targets
  host/
    whirlpool.zig      composes WM + Lua + UI + graphics
    studio.zig         composes Lua + UI + graphics + fixture world
```

The standalone `ui` and `script` modules are the useful Shoal capability
consumed by Whirlpool. They have no compositor-specific IPC facade because the
in-process host provides the same read/action contracts directly. A separate
adapter can expose those contracts to external clients later.

## Test strategy

1. The WM kernel exposes a pure `State + Command -> State + Events` harness.
   Model/property tests generate long mixed command and lifecycle traces, check
   invariants after every transition, shrink failures, and cover every tree
   operation, tag/output invariant, focus successor, constraint, stale handle,
   and geometry policy. Failed intent batches must leave byte-equivalent
   serialized policy state.
2. River trace tests replay object events and assert the complete ordered list
   of requests before each `manage_finish` and `render_finish`.
3. Lua contract tests run programs against fake snapshots and compare validated
   intent/effect batches. They require no Wayland socket.
4. Existing Tidepool behavior is captured as parity traces for scroll trees,
   directional actions, floats, fullscreen, tags, focus, animations, and
   persistence before those modules are replaced.
5. UI tests render components headlessly, assert layout/hit-test trees, and use
   deterministic pixel goldens for text/vector output.
6. Studio runs the exact Lua/UI/graphics stack with a fixture `WorldSnapshot`
   and no River globals.
7. Nested-River tests cover protocol lifecycle and Vulkan presentation only
   after the pure and trace layers pass.

## Capability migration checklist

The rewrite is not feature-complete until these groups are accounted for.

### Tidepool

- River v5 window/output/seat lifecycle and manage/render transactions;
- output usable areas and output configuration;
- tags, per-tag state, scratchpad, and multi-output reconciliation;
- layout trees, scroll camera, splits/tabs, built-in layouts;
- directional focus/swap, absorb/eject/expel, resizing, marks;
- floating/pointer operations, constraints/rules, fullscreen/maximize/minimize;
- bindings, cursor policy, borders/decorations, animation;
- persistence, IPC/action introspection, signals, restart/exit.

### Shoal

- component messages/state and declarative subscriptions/effects;
- dynamic/per-output/transient/offscreen surface lifecycle;
- keyed view tree, UI layout, theme/style system;
- text shaping, font fallback, measurement and caching;
- native animation and targeted invalidation;
- pointer/keyboard hit testing and interaction messages;
- timer/process/file/socket data sources;
- bars, OSDs, decorators, and Studio fixtures as library consumers.

## Recommended decisions to confirm

1. Use PUC Lua: integer IDs work naturally, the VM is small and predictable,
   and no current requirement justifies LuaJIT's FFI or Luau's larger language
   departure. Pin the exact release when implementation begins.
2. Stabilize the custom-layout contract now, but implement Tidepool-parity
   native layouts first. Custom Lua geometry is the next milestone rather than
   a prerequisite for the first usable manager.
3. Sandbox packages by default. All blocking or durable work goes through
   explicit effects; a separately enabled unsafe development mode is not part
   of the supported configuration API.
4. Use component-local state and explicit messages. Do not install a privileged
   global application store. A parent component or library service can provide
   shared state where a shell genuinely needs it.
