{
  lib,
  config,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.opt.crush;
in
{
  options.opt.crush = {
    enable = mkEnableOption "crush";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      nur.repos.charmbracelet.crush
    ];
  };
}
