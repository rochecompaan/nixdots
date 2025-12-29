{ config, lib, ... }:
let
  inherit (lib) getExe';
in
{
  "custom/quit" = {
    format = "󰗼";
    tooltip = false;
    on-click = "${getExe' config.wayland.windowManager.hyprland.package "hyprctl"} dispatch exit";
  };

  "hyprland/submap" = {
    format = "✌️ {}";
    max-length = 8;
    tooltip = false;
  };

  "hyprland/window" = {
    format = "{}";
    separate-outputs = true;
  };

  "hyprland/workspaces" = {
    format = "{name}";
    show-special = false;
    all-outputs = false;
    active-only = false;
    on-click = "activate";
    # Ensure Waybar shows exactly workspaces 1..10 per output.
    # This prevents an 11th workspace from appearing dynamically.
    "persistent-workspaces" = {
      "eDP-1" = [
        1
        2
        3
        4
        5
        6
        7
        8
        9
        10
      ];
      "HDMI-A-1" = [
        1
        2
        3
        4
        5
        6
        7
        8
        9
        10
      ];
      "DP-1" = [
        1
        2
        3
        4
        5
        6
        7
        8
        9
        10
      ];
      "DP-3" = [
        1
        2
        3
        4
        5
        6
        7
        8
        9
        10
      ];
      "DP-4" = [
        1
        2
        3
        4
        5
        6
        7
        8
        9
        10
      ];
      "DP-5" = [
        1
        2
        3
        4
        5
        6
        7
        8
        9
        10
      ];
      "DP-6" = [
        1
        2
        3
        4
        5
        6
        7
        8
        9
        10
      ];
      "DP-7" = [
        1
        2
        3
        4
        5
        6
        7
        8
        9
        10
      ];
    };
  };
}
