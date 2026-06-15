{
  config,
  lib,
  pkgs,
  ...
}:
let
  noctalia = lib.getExe config.programs.noctalia.package;

  firefoxProfiles = pkgs.writeShellApplication {
    name = "niri-firefox-profiles";
    runtimeInputs = [
      config.programs.firefox.package
      pkgs.coreutils
      pkgs.jq
      pkgs.niri
    ];
    text = builtins.readFile ./firefox-profiles.sh;
  };
in
{
  xdg.configFile."niri/config.kdl".text = ''
    // Autostart common desktop components
    spawn-at-startup "nm-applet"
    spawn-at-startup "blueman-applet"
    spawn-at-startup "element-desktop" "--hidden"
    spawn-at-startup "nextcloud" "--background"
    spawn-at-startup "${noctalia}"
    spawn-at-startup "${firefoxProfiles}/bin/niri-firefox-profiles"
  '';
}
