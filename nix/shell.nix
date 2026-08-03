{
  mkShell,
  pkg-config,
  zig_0_16,
}:
mkShell {
  packages = [
    pkg-config
    zig_0_16
  ];
}
