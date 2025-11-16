{ config, lib, ... }:
let
  cfg = config.desktop;
in
{
  options.desktop = {
    enable = lib.mkEnableOption "Desktop configuration";
    de = lib.mkOption {
      type = lib.types.enum [
        "hyprland"
        "niri"
      ];
      default = "hyprland";
      description = "Selected Wayland desktop environment/window manager.";
    };
  };

  config = lib.mkIf cfg.enable { };

  imports = [
    ./hardware.nix
    ./packages.nix
    ./portal.nix
    ./programs.nix
    ./qt.nix
    ./services.nix
  ];
}
