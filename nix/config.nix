# The example configuration: `whirlpool.lua` with its `lib/` beside it, where
# `require` finds it. Not installed with Whirlpool; exposed as
# `whirlpool.config`, the home-manager module's default.
{
  lib,
  runCommand,
}:
runCommand "whirlpool-config" {
  src = lib.fileset.toSource {
    root = ../config;
    fileset = ../config;
  };
} ''
  cp -r $src $out
''
