{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.modules.goose-cli;
  goose-pkg = pkgs.callPackage ./package.nix { };
in
{
  options.modules.goose-cli = {
    enable = mkEnableOption "Goose CLI - AI coding assistant by Block Inc";
  };

  config = mkIf cfg.enable {
    home.packages = [
      goose-pkg
    ];
  };
}
