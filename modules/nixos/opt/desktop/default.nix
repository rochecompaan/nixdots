{ config, lib, ... }:
let
  cfg = config.desktop;
in
{
  options.desktop = {
    enable = lib.mkEnableOption "Desktop configuration";
  };

  config = lib.mkIf cfg.enable {};

  imports = [
    ./hardware.nix
    ./packages.nix
    ./portal.nix
    ./programs.nix
    ./qt.nix
    ./services.nix
  ];
}
