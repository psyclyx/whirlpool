{ config, lib, pkgs, ... }:

let
  cfg = config.services.whirlpool;

  hasStylix = (config ? stylix) && (config.stylix.enable or false);

  # Lua modules generated here, as one directory on Whirlpool's module path
  # (`WHIRLPOOL_MODULES`): `foo.bar` is written to `foo/bar.lua`.
  modulesDir = pkgs.linkFarm "whirlpool-modules" (lib.mapAttrsToList (name: text: {
    name = "${lib.replaceStrings [ "." ] [ "/" ] name}.lua";
    path = pkgs.writeText "${name}.lua" text;
  }) cfg.modules);

  # The Stylix scheme as plain data. base24 schemes add base10..base17 (darker
  # backgrounds and bright accents); they are included when present.
  stylixData = let
    colors = config.lib.stylix.colors;
    slots = map (n: "base0${n}") [ "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "A" "B" "C" "D" "E" "F" ]
      ++ map (n: "base1${n}") [ "0" "1" "2" "3" "4" "5" "6" "7" ];
    fonts = config.stylix.fonts;
  in {
    colors = lib.listToAttrs (lib.concatMap
      (slot: lib.optional (colors ? ${slot}) (lib.nameValuePair slot colors.${slot}))
      slots);
    polarity = config.stylix.polarity or "either";
    opacity = config.stylix.opacity.desktop;
    fonts = {
      monospace = fonts.monospace.name;
      sans = fonts.sansSerif.name;
      size = fonts.sizes.desktop;
    };
  };
in
{
  options.services.whirlpool = {
    enable = lib.mkEnableOption "Whirlpool River window manager";

    package = lib.mkPackageOption pkgs "whirlpool" {
      default = pkgs.whirlpool;
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.package.config}/whirlpool.lua";
      defaultText = lib.literalExpression ''"''${cfg.package.config}/whirlpool.lua"'';
      description = "Whirlpool Lua configuration file. Modules in its directory (the default's `lib/`) are found by `require`.";
    };

    modules = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = ''
        Extra Lua modules the configuration can `require`, by module name
        (`foo.bar` becomes `foo/bar.lua`). They are found after modules beside
        the configuration, so the configuration can shadow them.

        With Stylix enabled, `stylix` defaults to the current scheme:
        `require("stylix")` returns `{ colors = { base00 = "1e1e2e", ... },
        polarity, opacity, fonts = { monospace, sans, size } }`, including
        base10..base17 for base24 schemes. Without Stylix nothing is added, so a
        configuration should treat it as optional (`pcall(require, "stylix")`).
      '';
      example = lib.literalExpression ''
        { "site.outputs" = "return { primary = \"DP-1\" }"; }
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional arguments passed to Whirlpool after the config.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf hasStylix {
      services.whirlpool.modules.stylix = lib.mkDefault
        "return ${lib.generators.toLua { } stylixData}\n";
    })
    {
      home.packages = [ cfg.package ];

      systemd.user.services.whirlpool = {
        Unit = {
          Description = "Whirlpool River window manager";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = lib.escapeShellArgs ([
            (lib.getExe cfg.package)
            "river"
            "--config"
            cfg.configFile
          ] ++ cfg.extraArgs);
          Environment = lib.optional (cfg.modules != { }) "WHIRLPOOL_MODULES=${modulesDir}";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    }
  ]);
}
