{ config, lib, pkgs, ... }:

let
  cfg = config.services.whirlpool;
in
{
  options.services.whirlpool = {
    enable = lib.mkEnableOption "Whirlpool River window manager";

    package = lib.mkPackageOption pkgs "whirlpool" {
      default = pkgs.whirlpool;
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.package}/share/whirlpool/config/whirlpool.lua";
      defaultText = lib.literalExpression ''"''${cfg.package}/share/whirlpool/config/whirlpool.lua"'';
      description = "Whirlpool Lua configuration file.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional arguments passed to Whirlpool after the config.";
    };
  };

  config = lib.mkIf cfg.enable {
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
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
