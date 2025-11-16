{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./config ];

  config = lib.mkIf (config.default.de == "hyprland") {
    home.packages = with pkgs; [
      config.wayland.windowManager.hyprland.package
      hyprpicker
      sassc
    ];

    wayland.windowManager.hyprland = {
      xwayland.enable = true;
      enable = true;
      systemd = {
        enable = true;
        extraCommands = lib.mkBefore [
          "systemctl --user stop graphical-session.target"
          "systemctl --user start hyprland-session.target"
        ];
      };
    };

    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = [ "graphical-session-pre.target" ];
      };
    };
  };
}
