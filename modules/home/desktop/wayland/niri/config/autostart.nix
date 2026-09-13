{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.niri.autostart;
  noctalia = lib.getExe config.programs.noctalia.package;

  firefoxProfileNames = [
    "default"
    "clubhouse"
    "clubhouse_prod"
    "siyavula"
    "mycity"
    "sixfeetup"
    "croprun"
    "agibase"
    "homelab"
  ];
  firefoxProfileArgs = lib.concatMapStringsSep " " (profile: ''"${profile}"'') cfg.firefoxProfiles;
  firefoxLauncher = pkgs.callPackage ../firefox-launcher/package.nix {
    firefox = config.programs.firefox.package;
  };
  firefoxProfiles = pkgs.writeShellApplication {
    name = "niri-firefox-profiles";
    runtimeInputs = [ firefoxLauncher ];
    text = builtins.readFile ./firefox-profiles.sh;
  };
in
{
  options.niri.autostart.firefoxProfiles = lib.mkOption {
    type = lib.types.nonEmptyListOf (lib.types.enum firefoxProfileNames);
    default = firefoxProfileNames;
    description = "Firefox profiles to launch when Niri starts";
  };

  config = {
    home.packages = [ firefoxProfiles ];

    xdg.configFile."niri/config.kdl".text = ''
      // Autostart common desktop components
      spawn-at-startup "1password"
      spawn-at-startup "nm-applet"
      spawn-at-startup "blueman-applet"
      spawn-at-startup "element-desktop" "--hidden"
      spawn-at-startup "nextcloud" "--background"
      spawn-at-startup "${noctalia}"
      spawn-at-startup "${firefoxProfiles}/bin/niri-firefox-profiles" ${firefoxProfileArgs}
    '';
  };
}
