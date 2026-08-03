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
  overlay = final: prev: mkPackages final prev.lib;
in
  {
    nixpkgs ? npins.nixpkgs,
    pkgs ? import nixpkgs { },
  }:
  let
    finalPkgs = pkgs.extend overlay;
  in
  rec {
    packages = mkPackages finalPkgs pkgs.lib;
    inherit overlay;
    shell = finalPkgs.callPackage ./nix/shell.nix { };
    default = packages.whirlpool;
  }
