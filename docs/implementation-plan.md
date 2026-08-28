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
- One shared Vulkan device/context with per-surface swapchains.
- Nix packaging, full unit/compile checks, and a nested River smoke command.

## Next slices

1. Add focused WSI failure-injection tests around swapchain recreation and
   partial initialization.
2. Drive redraw generations from real UI dirtiness and frame callbacks rather
   than a fixed polling cadence.
3. Exercise multi-output role creation, resize, retirement, and reconnect in
   the nested smoke gate.
4. Add validation-layer smoke coverage where a Vulkan validation layer is
   available.

## Constraints

- Keep Wayland proxy ownership in protocol-role modules.
- Keep Lua free of native handles and hidden side effects.
- Keep River's transaction commit edge allocation-free and infallible.
- Use Vulkan WSI for ordinary Wayland presentation. A future direct-scanout
  optimization must remain optional and must not replace the portable path.
- Treat the checked-in sample configuration and the packaged nested command as
  release gates.
