{
  lib,
  stdenv,
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

  nativeBuildInputs = [ zig_0_16.hook ];

  doCheck = true;
  zigCheckFlags = [ "test" ];

  meta = {
    description = "Window manager and graphical shell host for River";
    license = lib.licenses.mit;
    mainProgram = "whirlpool";
    platforms = lib.platforms.linux;
  };
})
