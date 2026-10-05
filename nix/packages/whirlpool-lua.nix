# Whirlpool's Lua standard library (`share/whirlpool/lua`). Plain files, no
# build.
{
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "whirlpool-lua";
  version = "0.1.0-dev";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = ../../lua;
  };

  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/whirlpool
    cp -r lua $out/share/whirlpool/
    runHook postInstall
  '';

  meta = {
    description = "Whirlpool's Lua standard library";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
