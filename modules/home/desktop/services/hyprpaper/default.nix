{
  lib,
  pkgs,
  config,
  ...
}:
{
  xdg.configFile."hypr/hyprpaper.conf".text = ''
    preload = ${config.wallpaper}
    wallpaper = , ${config.wallpaper}
  '';

  systemd.user.services.hyprpaper = {
    Unit = {
      Description = "Hyprland wallpaper daemon";
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
      PartOf = [ "graphical-session.target" ];
    };

    Service = {
      ExecStart = "${lib.getExe pkgs.hyprpaper}";
      Restart = "on-failure";
    };

    Install.WantedBy = [ "graphical-session.target" ];
  };
}
