{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.opt.browser.zen;
in
{
  options.opt.browser.zen = {
    enable = mkEnableOption "Enable Zen Browser";
  };

  config = mkIf cfg.enable {
    home.packages = [
      (pkgs.callPackage ./package.nix { })
    ];
  };
}
