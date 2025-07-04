{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.modules.opencode;
in
{
  options.modules.opencode = {
    enable = mkEnableOption "opencode - terminal-based AI coding assistant";
  };

  config = mkIf cfg.enable {
    home.packages = [
      pkgs.opencode
    ];
  };
}
