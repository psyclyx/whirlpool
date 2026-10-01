# Whirlpool architecture

Whirlpool keeps policy, compositor protocol, drawing, and presentation as four
separate concerns.

## Lua policy

Lua owns user configuration: bindings, rules, layouts, data sources, and
retained surface composition. A configuration registers each piece by key
through `require("whirlpool")` (`bind`, `layout`, `surface`, `source`):
registering under an existing key replaces it and registering nil removes it, so
there is no all-in-one program table and one configuration can build on
another. The registry is read once into typed Zig values. Wayland
proxies, Vulkan handles, pointers, and file descriptors never cross the Lua
boundary.

The sample configuration is a supported API example. Unknown fields, actions,
or invalid action arity fail during loading rather than becoming inert
configuration.

Bindings may belong to named one-shot modes. Whirlpool only enables the mode's
physical key bindings and returns to the default mode after one action; Lua
decides that the sample's modes mean set, focus, summon, send, or clear a
letter-named mark. The input mechanism has no knowledge of marks or layouts.

Layouts are executable user modules. A module may return a layout function or
a retained controller with layout, action, and presentation entry points. The
host gives the selected module a bounded, immutable, flat snapshot of windows,
outputs, tags, size constraints, and time. It accepts only validated leaf
effects and per-window frame plans. The snapshot contains no parent links,
groups, columns, strips, modes, weights, marks, or camera. Those relationships
exist only in the controller's retained Lua state.

Configured layout actions cross the binding boundary as an opaque name and
bounded string arguments. Reparenting, swapping, absorbing, ejecting,
summoning, marking, and directional traversal are ordinary Lua table
operations; Zig neither recognizes those verbs nor implements relational
effects for them. When a Lua operation has a compositor consequence, such as
closing or moving a focused group, Lua expands the group to its leaf window
IDs and returns an atomic batch of generic per-window effects.
Controllers may bracket an action batch with `begin_actions()` and
`finish_actions(commit)`. The host acknowledges it only after every returned
leaf effect validates and applies atomically, so retained Lua relationships can
roll back with a rejected native batch instead of diverging from compositor
facts.

`config/lib/scrolling.lua` is the sample scrolling policy; it is not an
installed stdlib algorithm and can be replaced without changing Zig. Its
strips, main/cross-axis mapping, axis reversal, focus traversal, insertion
policy, logical container focus, marks, and two-dimensional camera state are
retained Lua data. The bar consumes the controller's presentation data rather
than reconstructing a second model in Zig: each strip is a group,
floating/fullscreen/scratchpad windows have distinct groups, and an insertion
indicator identifies the destination for a new window. Whirlpool has no strip,
group, or layout-node identity and no structural command. It validates only
concrete host mechanisms such as focusing or closing a window, activating a
tag, changing a window's protocol state, or assigning a window to a tag and
output. Presentation has one logical `focused` item whether that item is a leaf
or group; it has no second selection model.

Projected presentation items may be ordinary flow items or zero-advance
overlays anchored at a flow boundary. The sample uses that generic distinction
for group and insertion lines, so moving a structural marker cannot change
window-item geometry. The host also reports exact leading and trailing clipped
pixel counts; Lua decides how those amounts become edge fades.

Time-dependent layouts use the same boundary. Zig adds a monotonic timestamp
to the snapshot and honors the plan's `needs_frame` flag at River's next safe
transaction edge. Lua retains motion state and chooses duration, easing,
retargeting, and which geometry changes animate. Each snapshot reports both
requested and actual client sizes plus size hints. Lua therefore computes
shared constraints from what clients actually occupy instead of assuming a
resize request succeeded. A frame entry may also provide a whole-window clip
relative to the content origin. This lets the controller keep border geometry
fixed while partially off-screen chrome shrinks through clipping and finally
disappears.

Three layers of Lua meet here, and they are kept apart:

- The runtime (Zig) supplies mechanisms: the retained UI tree and its layout
  engine (rows, columns, stacks, flex, alignment, measured text, hidden nodes),
  node geometry queries (`node:bounds()`), pointer events, surface actions,
  and measurement sources.
- The standard library (`lua/whirlpool`, embedded in the binary) is what any
  configuration would otherwise rewrite, with no opinion about appearance:
  the registration API, `whirlpool.surface` (service handlers by name, and
  `act` for host actions), `whirlpool.series` (rates and windows over
  timestamped samples), `whirlpool.pointer` (hit regions, hover, click,
  scroll), `whirlpool.scroll` (a scroll view that can reveal a child), and
  `whirlpool.format` (number formatting).
- The configuration composes them. The example's `config/lib` holds its
  opinions (the angled panels, plots, theme, bar, title bars, the scrolling
  layout, mark bindings) and `config/whirlpool.lua` is a short leaf that
  registers them. Modules beside the configuration are named by path
  (`lib/bar.lua` is `lib.bar`) and are available to every Lua state.

Layouts and surfaces run in their own Lua states, so a configuration names
them by module and passes options as plain data.

Every service a surface receives is an object of named fields, delivered to the
handler registered for its name: `desktop` (tags and the layout's projected
items with window metadata), `decoration`, `frame` (`now`), `pointer` (one
event per value), and one service per registered source. A surface answers with
actions (`surface.act("layout", ...)`, `surface.act("spawn", ...)`); the host
knows nothing about what a surface draws, where its buttons are, or how it
scrolls.

Sources are measured by host tasks at their own period and delivered as
timestamped series on the same clock as frame ticks: `t` plus one array per
field, with counters (network and disk bytes) left cumulative. Rates,
smoothing, zoom, and plot geometry are drawing policy, computed per frame from
sample times, so irregular or late samples land where they belong. Source
updates and pointer events are frame-class: they never wait for or cause a
River transaction. Only desktop state is presented atomically with River.

## Surfaces

A surface registration names a provider, role, placement, edge, height,
exclusive zone, and the content module that builds its retained tree. The sample
reuses the exact same shell source for two adapters:

- `river` + `shell` creates River-owned integrated UI synchronized with River
  render transactions.
- `layer-shell` + `shell` creates a portable `zwlr_layer_shell_v1` surface and
  never claims window-management authority.

There is no native bar type. A bar is merely UI content on an edge-anchored,
exclusive surface. The sample's bar is bottom-anchored and reserves 38 pixels.
Its River role receives desktop updates and pointer gestures; the portable
layer-shell role deliberately has no compositor-specific WM authority.

## River host

The River adapter owns generated River proxies and translates compositor facts
into the flat renderer-neutral WM model. Lua policy returns generic leaf
effects and per-window presentation plans; the host validates and applies them
only at River's transaction boundaries. Protocol `river_node_v1` handles stay
private to this adapter and are not layout nodes.

Shell and decoration surfaces are retained by role. River's
`sync_next_commit` remains the authority for coordinating a role's next
surface commit. The presentation callback is prepared before that promise and
committed at its infallible edge.

Whirlpool also binds River's separate `river_layer_shell_v1` WM extension. It
tracks per-output usable areas and per-seat layer focus so third-party clients
such as launchers can use `zwlr_layer_shell_v1` normally.

## Drawing

Retained Lua/UI trees are lowered to a small Skia draw list containing scalar
rectangles, bounded polygons, text, and icons. Polygon points are box-relative
and may extend outside `0..1`; layout remains rectangular while an ancestor's
ordinary clip property controls overflow. A role worker asks Skia Ganesh to
render that list directly into an imported Vulkan image. This keeps scene and
text behavior independent of DMA-BUF, Vulkan, and Wayland resource ownership
without a CPU pixel copy.

## Vulkan and Wayland

Every production surface role uses explicit DMA-BUF exchange without Vulkan
WSI. A graphics context selects a DRM render node through Vulkan DRM
properties, intersects Vulkan-importable modifiers with the compositor's
`zwp_linux_dmabuf_v1` advertisement, and allocates GBM storage on that device.

Each surface owns a bounded two-slot pool. Vulkan imports each DMA-BUF with its
explicit modifier and plane layout; Wayland imports the same planes as a
`wl_buffer`. A role worker performs Lua updates, lowering, and Skia rendering,
then releases queue-family ownership to `VK_QUEUE_FAMILY_FOREIGN_EXT`. The
Wayland thread only attaches a completed buffer, damages, and commits.

GPU completion and compositor release are distinct gates. A second slot may be
rendered while the compositor retains the current one, but no storage is reused
or destroyed until its actual `wl_buffer.release` event. Producer updates are
coalesced under backpressure and worker completion wakes the Wayland event loop.

## Lifetime order

On normal role retirement, queued work is discarded, workers stop, and every
compositor-owned DMA-BUF remains retained through release before the River role
destroys its `wl_surface`. On display loss, callbacks are detached first,
queued River transactions are drained, presenters are abandoned, role
bookkeeping is dropped, and the disconnected manager releases local storage.

## Validation

The supported checks are:

```sh
nix-shell -A shell --run \
  'zig build check && zig build test && zig build'

timeout 15 "$(nix-build -A whirlpool-nested)/bin/whirlpool-nested" \
  --config config/whirlpool.lua
```
