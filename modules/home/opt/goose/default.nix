{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.modules.goose-cli;
in
{
  options.modules.goose-cli = {
    enable = mkEnableOption "Goose CLI - AI coding assistant by Block Inc";
  };

  config = mkIf cfg.enable {
    home.packages = [
      pkgs.goose-cli
    ];
  };
}
