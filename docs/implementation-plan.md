# Implementation status

Whirlpool has one vertical Wayland host with River protocol adapters. UI and
presentation must remain reusable through other surface-role providers rather
than growing another application mode.

## Current path

- Typed Lua configuration and named actions.
- River v5 world staging, policy, transaction coordination, shell roles, and
  decorations.
- Retained Lua/UI composition lowered to Skia draw lists.
- User-owned Lua layout providers returning validated generic geometry plans.
- Generic Wayland surface ownership with protocol-specific role adapters.
- River layer-shell control for third-party clients and a standalone portable
  layer-shell runtime for Whirlpool UI.
- WSI-free Vulkan contexts with modifier-explicit, double-buffered DMA-BUF
  presentation for River and portable layer-shell surfaces.
- Nix packaging, full unit/compile checks, and a nested River smoke command.

## Next slices

1. Move DMA-BUF allocation/import off the Wayland thread as a bounded worker
   job; only protocol import and attach/commit belong on that thread.
2. Replace per-role render threads with a bounded process worker pool before
   adding notifications, launchers, and other shell surfaces.
3. Exercise multi-output role creation, resize, retirement, and reconnect in
   the nested smoke gate.
4. Add validation-layer smoke coverage where a Vulkan validation layer is
   available.

## Constraints

- Keep Wayland proxy ownership in protocol-role modules.
- Keep Lua free of native handles and hidden side effects.
- Keep River's transaction commit edge allocation-free and infallible.
- Use modifier-explicit DMA-BUFs for every production Wayland presentation
  path; never reintroduce a CPU upload or swapchain fallback silently.
- Treat the checked-in sample configuration and the packaged nested command as
  release gates.
