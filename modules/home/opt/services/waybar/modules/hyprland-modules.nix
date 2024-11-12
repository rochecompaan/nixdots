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
    all-outputs = true;
    active-only = false;
    on-click = "activate";
  };
}
