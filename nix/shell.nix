{
  mkShell,
  libGL,
  pkg-config,
  wayland,
  wayland-protocols,
  wayland-scanner,
  zig_0_16,
}:
mkShell {
  packages = [
    libGL
    pkg-config
    wayland
    wayland-protocols
    wayland-scanner
    zig_0_16
  ];
}
