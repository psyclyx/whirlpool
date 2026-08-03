{
  callPackage,
  lib,
  libGL,
  pkg-config,
  stdenv,
  wayland,
  wayland-protocols,
  wayland-scanner,
  zig_0_16,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "whirlpool";
  version = "0.1.0-dev";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../build.zig
      ../../build.zig.zon
      ../../src
    ];
  };

  deps = callPackage ../../build.zig.zon.nix { };

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    zig_0_16.hook
  ];

  buildInputs = [
    libGL
    wayland
    wayland-protocols
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
  ];

  doCheck = true;
  zigCheckFlags = finalAttrs.zigBuildFlags ++ [ "test" ];

  meta = {
    description = "Window manager and graphical shell host for River";
    license = lib.licenses.mit;
    mainProgram = "whirlpool";
    platforms = lib.platforms.linux;
  };
})
