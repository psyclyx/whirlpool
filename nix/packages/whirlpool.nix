{
  callPackage,
  dejavu_fonts,
  fontconfig,
  harfbuzz,
  lua5_4,
  libdrm,
  libgbm,
  lib,
  makeWrapper,
  pkg-config,
  skia,
  stdenv,
  wayland,
  wayland-protocols,
  wayland-scanner,
  vulkan-headers,
  vulkan-loader,
  whirlpoolRiverSource,
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
      ../../protocol
      ../../src
      ../../lua
      ../../config
      ../../scripts
      ../../docs/operational-smoke.md
    ];
  };

  postPatch = ''
    cmp \
      ${whirlpoolRiverSource}/protocol/river-window-management-v1.xml \
      protocol/river-window-management-v1.xml
  '';

  postInstall = ''
    wrapProgram $out/bin/whirlpool \
      --set-default WHIRLPOOL_CONFIG "$out/share/whirlpool/config/whirlpool.lua" \
      --set LUA_PATH "$out/share/whirlpool/lua/?.lua;$out/share/whirlpool/lua/?/init.lua;$out/share/whirlpool/lua/?/?.lua;;"
    install -Dm755 scripts/compositor-free-smoke.sh $out/bin/whirlpool-compositor-free-smoke
    install -Dm755 scripts/nested-river-smoke.sh $out/bin/whirlpool-nested-river-smoke
    install -Dm644 scripts/smoke-common.sh $out/share/whirlpool/scripts/smoke-common.sh
    install -Dm644 scripts/smoke-common.sh $out/bin/smoke-common.sh
    install -Dm644 docs/operational-smoke.md $out/share/doc/whirlpool/operational-smoke.md
    install -Dm644 config/whirlpool.lua $out/share/whirlpool/config/whirlpool.lua
    install -Dm644 config/lib/scrolling.lua $out/share/whirlpool/config/lib/scrolling.lua
  '';

  deps = callPackage ../../build.zig.zon.nix { };

  nativeBuildInputs = [
    makeWrapper
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
    wayland
    wayland-protocols
    vulkan-headers
    vulkan-loader
    skia
    stdenv.cc.cc.lib
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
  ];

  doCheck = true;
  preCheck = ''
    export LD_LIBRARY_PATH="${lua5_4}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export WHIRLPOOL_FONT_DIR=${dejavu_fonts}/share/fonts/truetype
  '';
  zigCheckFlags = finalAttrs.zigBuildFlags ++ [ "test" ];

  meta = {
    description = "Window manager and graphical shell host for River";
    license = lib.licenses.mit;
    mainProgram = "whirlpool";
    platforms = lib.platforms.linux;
  };
})
