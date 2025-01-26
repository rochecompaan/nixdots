{ config, lib, ... }:

let
  cfg = config.desktop;
in
{
  config = lib.mkIf cfg.enable {
    qt = {
      enable = true;
      platformTheme = "gtk2";
      style = "gtk2";
    };
  };
}
