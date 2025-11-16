{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./config ];

  config = lib.mkIf (config.default.de == "niri") {
    home.packages = with pkgs; [ niri ];

    # Optional tray target for consistency
    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = [ "graphical-session-pre.target" ];
      };
    };
  };
}
