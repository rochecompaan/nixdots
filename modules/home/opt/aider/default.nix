{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.modules.aider;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.aider-chat
    ];
  };
}
