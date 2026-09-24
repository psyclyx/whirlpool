let
  npins = import ./npins;

  mkPackages = pkgs: lib:
    if builtins.pathExists ./nix/packages then
      lib.packagesFromDirectoryRecursive {
        inherit (pkgs) callPackage;
        directory = ./nix/packages;
      }
    else
      { };

  # Package calls are scoped against `final` so packages under nix/packages
  # can refer to one another. Directory discovery uses `prev.lib` to avoid
  # asking for an attribute of the fixpoint while its overlay keys are still
  # being formed.
in
  {
    sources ? npins,
    nixpkgs ? sources.nixpkgs,
    # External dep — river is consumed as a source checkout (its overlay +
    # the whirlpoolRiverSource fixture); default to whirlpool's own pin.
    river ? npins.river,
    pkgs ? import nixpkgs { },
    ...
  }:
  let
    overlay = final: prev:
      ((import "${river}/overlay.nix") final prev)
      // (mkPackages final prev.lib)
      // {
        whirlpoolRiverSource = river;
      };
    finalPkgs = pkgs.extend overlay;
    basePackages = mkPackages finalPkgs pkgs.lib;
    whirlpoolNested = finalPkgs.writeShellScriptBin "whirlpool-nested" ''
      set -eu

      config="''${WHIRLPOOL_CONFIG:-${basePackages.whirlpool}/share/whirlpool/config/whirlpool.lua}"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --config)
            [ "$#" -ge 2 ] || { echo "whirlpool-nested: --config requires a path" >&2; exit 2; }
            config="$2"
            shift 2
            ;;
          --config=*)
            config="''${1#--config=}"
            shift
            ;;
          *)
            echo "whirlpool-nested: unknown argument: $1" >&2
            exit 2
            ;;
        esac
      done
      case "$config" in
        /*) ;;
        *) config="$PWD/$config" ;;
      esac
      lua_path="${basePackages.whirlpool}/share/whirlpool/lua/?.lua;${basePackages.whirlpool}/share/whirlpool/lua/?/init.lua;${basePackages.whirlpool}/share/whirlpool/lua/?/?.lua;;"
      export WHIRLPOOL_CONFIG="$config"
      export LUA_PATH="$lua_path"
      # Keep configured spawns self-contained when this launcher is built from
      # Nix; in particular Alt+d must resolve Fuzzel in the nested session.
      export PATH="${finalPkgs.fuzzel}/bin:$PATH"
      export WLR_BACKENDS="''${WLR_BACKENDS:-wayland}"
      export WLR_LIBINPUT_NO_DEVICES="''${WLR_LIBINPUT_NO_DEVICES:-1}"

      # The command passed to River runs inside the newly-created nested
      # session, where River has already set WAYLAND_DISPLAY for us.
      exec ${finalPkgs.river}/bin/river -c \
        "exec ${basePackages.whirlpool}/bin/whirlpool river --config \"$config\""
    '';
  in
  rec {
    packages = basePackages // {
      whirlpool-nested = whirlpoolNested;
    };
    inherit overlay;
    homeManagerModules.default = import ./nix/hm-module.nix;
    shell = finalPkgs.callPackage ./nix/shell.nix { };
    default = packages.whirlpool;
    whirlpool-nested = whirlpoolNested;
  }
