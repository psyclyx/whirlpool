# The Zig build alone: the `whirlpool` executable, without the Lua library
# (`whirlpool-lua`), so changing it never rebuilds this.
# Composed into a runnable package by `whirlpool`. Tests are off: some read
# Lua from the source tree, which this source leaves out.
{
  callPackage,
  dejavu_fonts,
  fontconfig,
  harfbuzz,
  lua5_4,
  libdrm,
  libgbm,
  librsvg,
  lib,
  pkg-config,
  stdenv,
  wayland,
  wayland-protocols,
  wayland-scanner,
  vulkan-headers,
  vulkan-loader,
  whirlpool-skia,
  whirlpoolRiverSource,
  zig_0_16,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "whirlpool-unwrapped";
  version = "0.1.0-dev";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../build.zig
      ../../build.zig.zon
      ../../protocol
      ../../src
    ];
  };

  postPatch = ''
    cmp \
      ${whirlpoolRiverSource}/protocol/river-window-management-v1.xml \
      protocol/river-window-management-v1.xml
  '';

  deps = callPackage ../../build.zig.zon.nix { };

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    zig_0_16.hook
  ];

  buildInputs = [
    dejavu_fonts
    fontconfig
    harfbuzz
    lua5_4
    libdrm
    libgbm
    librsvg
    wayland
    wayland-protocols
    vulkan-headers
    vulkan-loader
    whirlpool-skia
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dcpu=baseline"
    "-Dinstall-lua=false"
    "--release=fast"
  ];
  dontSetZigDefaultFlags = true;

  doCheck = false;
  preCheck = ''
    export LD_LIBRARY_PATH="${lua5_4}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export WHIRLPOOL_FONT_DIR=${dejavu_fonts}/share/fonts/truetype
  '';
  zigCheckFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dcpu=baseline"
    "--release=safe"
  ];

  meta = {
    description = "Whirlpool executable, without its Lua library";
    license = lib.licenses.mit;
    mainProgram = "whirlpool";
    platforms = lib.platforms.linux;
  };
})
