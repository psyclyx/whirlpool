# Operational smoke coverage

The smoke scripts validate launch behavior without duplicating compositor or
graphics implementation in the test harness.

## Deterministic gate

```sh
scripts/compositor-free-smoke.sh
```

This runs the full unit suite and compile check with Skia and Vulkan Wayland
presentation enabled. It uses a temporary Zig cache so read-only home caches
in Nix sandboxes do not affect the result.

## Nested River gate

```sh
scripts/nested-river-smoke.sh --allow-skip
```

After the deterministic gate, this launches River on the existing Wayland
session with Whirlpool as River's init process. It verifies that the sample Lua
configuration loads, all configured bindings are installed, the River shell
surface commits its first frame, Whirlpool remains connected for the watchdog
interval, and shutdown emits no application error.
An unavailable parent Wayland session is reported as a dependency skip when
`--allow-skip` is supplied.

The packaged equivalent is:

```sh
timeout 15 "$(nix-build -A whirlpool-nested)/bin/whirlpool-nested" \
  --config config/whirlpool.lua
```
