{ inputs, lib, ... }:
{
  theme = "gruvbox";

  imports = [
    inputs.stylix.homeModules.stylix
    inputs.krewfile.homeManagerModules.krewfile
    ../../modules/home
    ../../modules/home/desktop
  ];

  home.sessionVariables.TERMINAL = "foot";

  default = {
    de = "niri";
    terminal = "kitty";
  };

  # Idle suspend after 30 minutes
  services.hypridle.settings.listener = [
    {
      timeout = 1800;
      on-timeout = "systemctl suspend";
    }
  ];

  wayland.windowManager.hyprland.settings = {
    monitor = [
      "HDMI-A-1, 1920x1080@74.97, 0x0, auto"
      "eDP-1, 1920x1080@165, 1920x0, auto"
    ];

    # workspace rules
    workspace = [
      "1,monitor:HDMI-A-1"
      "2,monitor:HDMI-A-1"
      "3,monitor:HDMI-A-1"
      "4,monitor:HDMI-A-1"
      "5,monitor:HDMI-A-1"
      "6,monitor:HDMI-A-1"
      "7,monitor:HDMI-A-1"
      "8,monitor:eDP-1"
      "9,monitor:eDP-1"
      "10,monitor:eDP-1"
    ];
  };

  # Niri: host-specific config additions (output mode, keybinds, named workspaces)
  # Append to the main Niri config in a single block to avoid duplicate option definitions.
  xdg.configFile."niri/config.kdl".text = lib.mkAfter ''
    // Output mode override for internal panel
    output "eDP-1" {
      mode "1920x1200@165.002"
    }

    // Keybinds are defined in a single global `binds { ... }` node supplied by
    // modules/home/desktop/wayland/niri/config/binds.nix to avoid duplicates.

    // Named workspaces 1..10 so they always exist.
    // Declare in reverse order to account for live-reload behavior where
    // newly declared workspaces are inserted at the top; this results in
    // 1..10 top-to-bottom and left-to-right in Waybar.
    workspace "10"
    workspace "9"
    workspace "8"
    workspace "7"
    workspace "6"
    workspace "5"
    workspace "4"
    workspace "3"
    workspace "2"
    workspace "1"
  '';

}
