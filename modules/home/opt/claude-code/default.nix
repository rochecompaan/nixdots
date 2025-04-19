{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.modules.claude-code;
in
{
  options.modules.claude-code = {
    enable = mkEnableOption "Claude Code - AI coding assistant by Anthropic";
  };

  config = mkIf cfg.enable {
    home.packages = [
      pkgs.claude-code
    ];
  };
}
