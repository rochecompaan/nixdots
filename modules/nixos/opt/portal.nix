{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.desktop;
in
{
  config = lib.mkIf cfg.enable {
    xdg.portal = {
      enable = true;
      xdgOpenUsePortal = true;
      config = {
        common.default = [ "hyprland" ];
        hyprland.default = [ "hyprland" ];
      };

      extraPortals = [
        pkgs.xdg-desktop-portal-gtk
        pkgs.xdg-desktop-portal-wlr
      ];
    };
  };
}
