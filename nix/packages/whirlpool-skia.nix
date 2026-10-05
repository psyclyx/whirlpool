# Skia as Whirlpool uses it, compiled by Zig: a static library against Zig's
# libc++, so Whirlpool (whose C++ shim Zig also compiles) carries exactly one
# C++ toolchain and runtime. Only what Whirlpool draws with: Vulkan, no GL,
# X11 or ICU (Whirlpool shapes no text; ICU would bring libstdc++ back in).
{
  lib,
  skia,
  stdenv,
  writeShellScript,
  zig_0_16,
}:
let
  target = "${stdenv.hostPlatform.parsed.cpu.name}-linux-gnu";
  # Nix passes dependencies' include paths in NIX_CFLAGS_COMPILE, which the
  # usual cc wrapper adds and Zig does not: add them here, when compiling.
  # Zig reads `-march` as its `-mcpu`, where `-` removes a feature: Skia's
  # `-march=skylake-avx512` is Zig's `skylake_avx512`.
  zigCc = mode: writeShellScript "zig-${mode}" ''
    export ZIG_GLOBAL_CACHE_DIR="''${ZIG_GLOBAL_CACHE_DIR:-$TMPDIR/zig-cache}"
    args=()
    for arg in "$@"; do
      case "$arg" in
        -march=*) cpu="''${arg#-march=}"; args+=("-mcpu=''${cpu//-/_}") ;;
        *) args+=("$arg") ;;
      esac
    done
    exec ${lib.getExe zig_0_16} ${mode} -target ${target} $NIX_CFLAGS_COMPILE "''${args[@]}"
  '';
  replaced = flag: !(lib.any (prefix: lib.hasPrefix prefix flag) [
    "cc="
    "cxx="
    "ar="
    "is_component_build="
  ]);
in
skia.overrideAttrs (old: {
  pname = "whirlpool-skia";

  gnFlags = lib.filter replaced old.gnFlags ++ [
    "cc=\"${zigCc "cc"}\""
    "cxx=\"${zigCc "c++"}\""
    "ar=\"${lib.getExe zig_0_16} ar\""
    "is_component_build=false"
    "skia_use_gl=false"
    "skia_use_x11=false"
    "skia_use_icu=false"
  ];

  ninjaFlags = [ "skia" ];

  meta = old.meta // {
    description = "Skia compiled by Zig, as a static library, for Whirlpool";
  };
})
