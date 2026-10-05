# Whirlpool as installed: the executable from `whirlpool-unwrapped` beside the
# Lua library from `whirlpool-lua`, plus the smoke scripts. Composing is a
# copy, so a Lua change rebuilds only `whirlpool-lua` and this. The example
# configuration is `whirlpool.config`, a separate derivation.
{
  callPackage,
  coreutils,
  lib,
  lua5_4,
  makeWrapper,
  pulseaudio,
  stdenvNoCC,
  whirlpool-lua,
  whirlpool-unwrapped,
}:
stdenvNoCC.mkDerivation {
  pname = "whirlpool";
  inherit (whirlpool-unwrapped) version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../scripts
      ../../docs/operational-smoke.md
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;
  # The executable finds its library at `<its directory>/../share/whirlpool/lua`,
  # resolving symlinks, so it is copied here rather than linked.
  installPhase = ''
    runHook preInstall
    install -Dm755 ${whirlpool-unwrapped}/bin/whirlpool $out/bin/whirlpool
    mkdir -p $out/share/whirlpool
    ln -s ${whirlpool-lua}/share/whirlpool/lua $out/share/whirlpool/lua
    # The status sources run `pactl` (audio) and `df` (disks). They are
    # appended, so the session's own tools come first. `zfs`/`zpool` and
    # `nvidia-smi` must match the running kernel module and driver, so they
    # come from the system: on NixOS, /run/current-system/sw/bin.
    wrapProgram $out/bin/whirlpool \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ lua5_4 ]}" \
      --suffix PATH : "${lib.makeBinPath [ pulseaudio coreutils ]}"
    install -Dm755 scripts/compositor-free-smoke.sh $out/bin/whirlpool-compositor-free-smoke
    install -Dm755 scripts/nested-river-smoke.sh $out/bin/whirlpool-nested-river-smoke
    install -Dm644 scripts/smoke-common.sh $out/share/whirlpool/scripts/smoke-common.sh
    install -Dm644 scripts/smoke-common.sh $out/bin/smoke-common.sh
    install -Dm644 docs/operational-smoke.md $out/share/doc/whirlpool/operational-smoke.md
    runHook postInstall
  '';

  passthru = {
    inherit whirlpool-lua whirlpool-unwrapped;
    config = callPackage ../config.nix { };
  };

  meta = whirlpool-unwrapped.meta // {
    description = "Window manager and graphical shell host for River";
  };
}
