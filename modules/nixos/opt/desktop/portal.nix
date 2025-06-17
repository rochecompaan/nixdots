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
        # For applications running under Hyprland
        hyprland = {
          default = [ "hyprland" "gtk" ]; # Prioritize hyprland, fallback to gtk
        };
        # Fallback for other cases
        common = {
          default = [ "hyprland" "gtk" ]; # Prioritize hyprland, fallback to gtk
        };
      };

      extraPortals = [
        pkgs.xdg-desktop-portal-hyprland # Ensure hyprland portal is installed
        pkgs.xdg-desktop-portal-gtk
        pkgs.xdg-desktop-portal-wlr
      ];
    };
  };
}
