# Whirlpool architecture

Whirlpool keeps policy, compositor protocol, drawing, and presentation as four
separate concerns.

## Lua policy

Lua owns user configuration: bindings, rules, layouts, and retained shell
composition. Configuration is loaded once into typed Zig values. Wayland
proxies, Vulkan handles, pointers, and file descriptors never cross the Lua
boundary.

The sample configuration is a supported API example. Unknown fields, actions,
or invalid action arity fail during loading rather than becoming inert
configuration.

Layouts are executable user modules. The host gives the selected module a
bounded, immutable world snapshot and accepts a validated generic geometry
plan. `config/lib/scrolling.lua` is the sample scrolling policy; it is not an
installed stdlib algorithm and can be replaced without changing Zig.

Workspace actions are likewise an ordinary Lua convention.
`whirlpool.workspace` constructs semantic action values without exposing
compositor objects. The sample shell consumes the generic `desktop` service
for workspace occupancy, focused-window metadata, and its layout minimap.

Widget policy remains in Lua. `whirlpool.shell` composes the retained bar and
OSD, `whirlpool.decorator` owns title/tab presentation, `whirlpool.status`
polls portable operating-system status sources, and `whirlpool.theme` is the
shared color vocabulary. None of those modules owns a Wayland proxy or River
transaction.

## Surfaces

The program declares generic surface descriptors containing a provider, role,
placement, edge, height, exclusive zone, and retained Lua content. The sample
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
into the renderer-neutral WM model. Policy produces typed intents; the host
applies those intents only at River's transaction boundaries.

Shell and decoration surfaces are retained by role. River's
`sync_next_commit` remains the authority for coordinating a role's next
surface commit. The presentation callback is prepared before that promise and
committed at its infallible edge.

Whirlpool also binds River's separate `river_layer_shell_v1` WM extension. It
tracks per-output usable areas and per-seat layer focus so third-party clients
such as launchers can use `zwlr_layer_shell_v1` normally.

## Drawing

Retained Lua/UI trees are lowered to a small Skia draw list containing scalar
rectangles and text. A role worker asks Skia Ganesh to render that list directly
into an imported Vulkan image. This keeps scene and text behavior independent
of DMA-BUF, Vulkan, and Wayland resource ownership without a CPU pixel copy.

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
