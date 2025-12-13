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
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Hyprland portal configuration
      (lib.mkIf (config.desktop.de == "hyprland") {
        xdg.portal = {
          enable = true;
          xdgOpenUsePortal = true;
          config = {
            # For applications running under Hyprland
            hyprland = {
              default = [
                "hyprland"
                "gtk"
              ]; # Prioritize hyprland, fallback to gtk
            };
            # Fallback for other cases
            common = {
              default = [
                "hyprland"
                "gtk"
              ]; # Prioritize hyprland, fallback to gtk
            };
          };

          # Use a single backend for Hyprland to avoid portal deadlocks.
          # Hyprland recommends its portal; GTK stays for common dialogs.
          extraPortals = [
            pkgs.xdg-desktop-portal-hyprland
            pkgs.xdg-desktop-portal-gtk
          ];
        };
      })

      # Niri portal configuration (upstream recommends GNOME portal)
      (lib.mkIf (config.desktop.de == "niri") {
        xdg.portal = {
          enable = true;
          xdgOpenUsePortal = true;
          config = {
            common = {
              # Prefer GNOME portal for screencast, then GTK
              default = [
                "gnome"
                "gtk"
              ];
            };
          };
          extraPortals = [
            pkgs.xdg-desktop-portal-gnome
            pkgs.xdg-desktop-portal-gtk
          ];
        };
      })
    ]
  );
}
