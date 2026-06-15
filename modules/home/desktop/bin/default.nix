{ config, pkgs, ... }:
let
  firefox = "${config.programs.firefox.package}/bin/firefox";
  realXdgOpen = "${pkgs.xdg-utils}/bin/xdg-open";
in
{
  home = {
    file = {
      ".local/bin/xdg-open" = {
        executable = true;
        text = ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          case "''${1-}" in
            http://*|https://*)
              if [ -n "''${FIREFOX_PROFILE:-}" ]; then
                exec ${firefox} -P "''${FIREFOX_PROFILE}" "$1"
              fi

              exec ${firefox} "$1"
              ;;
            *)
              exec ${realXdgOpen} "$@"
              ;;
          esac
        '';
      };
      ".local/bin/thisisfine" = {
        executable = true;
        text = import ./misc/thisisfine.nix { };
      };
      ".local/bin/fetch" = {
        executable = true;
        text = import ./eyecandy/nixfetch.nix { };
      };
      ".local/bin/powermenu" = {
        executable = true;
        text = import ./rofiscripts/powermenu.nix { };
      };
      ".local/bin/captureCode" = {
        executable = true;
        text = import ./screenshot/captureCode.nix { inherit config; };
      };
      ".local/bin/captureAll" = {
        executable = true;
        text = import ./screenshot/captureAll.nix { };
      };
      ".local/bin/captureArea" = {
        executable = true;
        text = import ./screenshot/captureArea.nix { inherit config; };
      };
      ".local/bin/captureWindow" = {
        executable = true;
        text = import ./screenshot/captureWindow.nix { inherit config; };
      };
      ".local/bin/captureScreen" = {
        executable = true;
        text = import ./screenshot/captureScreen.nix { };
      };
      ".local/bin/screenshot" = {
        executable = true;
        text = import ./rofiscripts/screenshot.nix { };
      };
    };
  };
}
