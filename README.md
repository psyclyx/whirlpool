# Whirlpool

Whirlpool is a new River window manager and graphical shell host. It is a
rewrite informed by Tidepool and Shoal, built around current Zig and Snail
rather than a source transplant from either project.

## Direction

- Whirlpool owns the River connection, window/output model, event loop, and
  graphics context.
- `whirlpool-model` is a pure state machine. It contains no protocol proxies,
  sockets, rendering handles, or global state.
- `whirlpool-shell` is the reusable part of the Shoal idea: host-independent
  shell surfaces and views. It is consumed by Whirlpool rather than owning
  Wayland or graphics APIs itself.
- Platform adapters translate River/Wayland events into model operations.
  Rendering reads model and shell state but cannot mutate it implicitly.
- `whirlpool studio` is the graphics iteration entry point. It creates an
  ordinary xdg-shell preview surface and a caller-owned Vulkan context
  without importing or binding River's window-management protocols.

Studio exercises configure/resize, frame callbacks, a Vulkan Wayland swapchain,
and a current Snail 0.17 vector scene. Whirlpool owns the pixels and staging;
the initial deterministic `snail-raster` path will be replaced by a persistent
GPU atlas renderer without changing the shell or window-model boundaries.

## Development

Enter the pinned development environment with direnv or Nix:

```sh
direnv allow
nix-shell -A shell
```

Common commands:

```sh
zig build test
zig build check
zig build run -- studio
nix-build
```

## Testing strategy

Window behavior is tested at three layers:

1. Pure model tests cover lifecycle, focus repair, tags, output removal, and
   cross-output moves with no compositor involved.
2. Adapter contract tests will replay captured River event sequences into the
   model and assert emitted protocol requests.
3. End-to-end tests will run a nested compositor for protocol and rendering
   smoke coverage.

Most behavioral combinations belong in layer 1 so they stay deterministic,
fast, and easy to run under sanitizers and allocation checking.

## License

MIT. See [LICENSE](LICENSE).
