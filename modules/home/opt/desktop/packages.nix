{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf;
in
{
  config = mkIf config.default.isDesktop {
    home.packages = with pkgs; [
      libreoffice
      obs-studio
      signal-desktop
      qbittorrent-cli
      qbittorrent-enhanced
      transmission_4
      ssh-to-age
      stretchly
      keymapp
      ydotool
      wlprop
      xorg.xprop
    ];
  };
}
