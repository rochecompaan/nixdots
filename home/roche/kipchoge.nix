{
  inputs,
  lib,
  ...
}:
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

  # Niri: host-specific output mode, scale, and named workspaces.
  # Append to the main Niri config in a single block to avoid duplicate option definitions.
  xdg.configFile."niri/config.kdl".text = lib.mkAfter ''
    output "HDMI-A-1" {
      mode "3840x2160@60"
      scale 2
      position x=0 y=0
    }

    output "DP-1" {
      mode "3840x2160@60"
      scale 2
      position x=1920 y=0
    }

    // Named persistent workspaces pinned to outputs.
    workspace "1" { open-on-output "HDMI-A-1"; }
    workspace "2" { open-on-output "HDMI-A-1"; }
    workspace "3" { open-on-output "HDMI-A-1"; }
    workspace "4" { open-on-output "HDMI-A-1"; }
    workspace "5" { open-on-output "HDMI-A-1"; }
    workspace "6" { open-on-output "DP-1"; }
    workspace "7" { open-on-output "DP-1"; }
    workspace "8" { open-on-output "DP-1"; }
    workspace "9" { open-on-output "DP-1"; }
    workspace "10" { open-on-output "DP-1"; }
  '';

  programs.element-desktop.enable = true;

}
