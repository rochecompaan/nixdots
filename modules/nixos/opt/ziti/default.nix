{
  lib,
  config,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.programs.ziti;
in
{
  options.programs.ziti = {
    enable = mkEnableOption "Ziti CLI";
  };

  config = mkIf cfg.enable {
    nixpkgs.overlays = [
      (_: prev: {
        ziti-cli = prev.callPackage ./package.nix { };
      })
    ];

    environment.systemPackages = [ pkgs.ziti-cli ];
  };
}
