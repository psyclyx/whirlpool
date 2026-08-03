{
  mkShell,
  harfbuzz,
  pkg-config,
  wayland,
  wayland-protocols,
  wayland-scanner,
  vulkan-headers,
  vulkan-loader,
  zig_0_16,
}:
mkShell {
  packages = [
    harfbuzz
    pkg-config
    wayland
    wayland-protocols
    wayland-scanner
    vulkan-headers
    vulkan-loader
    zig_0_16
  ];
}
