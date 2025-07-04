{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

with lib;
let
  cfg = config.modules.opencode;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.system};
in
{
  options.modules.opencode = {
    enable = mkEnableOption "opencode - terminal-based AI coding assistant";
  };

  config = mkIf cfg.enable {
    home.packages = [ (pkgs-unstable.callPackage ./package.nix { }) ];
  };
}
