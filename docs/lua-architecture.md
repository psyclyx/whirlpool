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

Workspace state and actions are likewise an ordinary Lua convention.
`whirlpool.workspace` implements that convention over generic named service
updates and semantic action values. UI may substitute another module backed by
another compositor without changing surface or rendering code.

## Surfaces

The program declares generic surface descriptors containing a provider, role,
placement, and retained Lua content. The sample reuses the exact same content
source for two adapters:

- `river` + `shell` creates River-owned integrated UI synchronized with River
  render transactions.
- `layer-shell` + `shell` creates a portable `zwlr_layer_shell_v1` surface and
  never claims window-management authority.

There is no native bar type. A bar is merely UI content on a top-anchored,
exclusive surface.

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
rectangles and text. Skia rasterizes to BGRA host memory. This keeps scene and
text behavior independent of Vulkan resource ownership.

## Vulkan and Wayland

Every surface role uses the same Wayland surface host and Vulkan presentation
boundary. Once per process:

1. Create `VkInstance` with `VK_KHR_wayland_surface`.
2. Select a graphics queue with Wayland presentation support and create one
   logical device.

Then, once per `wl_surface`:

1. Create its `VkSurfaceKHR` and verify support on the shared queue.
2. Create a FIFO `VK_KHR_swapchain` swapchain.
3. Copy the Skia frame through one host-visible staging buffer into an acquired
   BGRA swapchain image.
4. Present with `vkQueuePresentKHR`.

Vulkan WSI owns buffer exchange and compositor synchronization. Whirlpool does
not negotiate linux-dmabuf feedback, choose DRM modifiers or render nodes,
export memory FDs, translate synchronization FDs, or manage DRM syncobj
timelines.

The process owns one Vulkan device/context. Each `wl_surface` owns only its
role-specific state and swapchain. A nonblocking fence check provides
backpressure; image reuse is still governed by `vkAcquireNextImageKHR`.

## Lifetime order

On normal role retirement, queued work is discarded or completed, the Vulkan
surface is destroyed, and only then may the River role destroy its
`wl_surface`. On display loss, callbacks are detached first, queued River
transactions are drained, presenters are abandoned, role bookkeeping is
dropped, and the disconnected manager releases its local storage.

## Validation

The supported checks are:

```sh
nix-shell -A shell --run \
  'zig build check && zig build test && zig build'

timeout 15 "$(nix-build -A whirlpool-nested)/bin/whirlpool-nested" \
  --config config/whirlpool.lua
```
