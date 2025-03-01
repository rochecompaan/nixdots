{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.desktop;
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      # Media & Creative
      blender
      ffmpeg_7-full
      mpv
      obs-studio

      # Desktop environment
      blueman
      brightnessctl
      dosis
      grim
      gtk3
      hyprland
      kanata
      pamixer
      pulseaudio
      slack
      slack-term
      slop
      srt
      (lib.mkIf config.wayland.enable wayland)
      xdg-utils

      # Development GUI
      nodejs
      yaml-language-server

      # Security/Hardware GUI
      pass
      yubico-piv-tool
      yubikey-manager
      yubikey-personalization

      # 3D Printing
      (
        let
          cura5 = appimageTools.wrapType2 rec {
            name = "cura5";
            version = "5.4.0";
            src = fetchurl {
              url = "https://github.com/Ultimaker/Cura/releases/download/${version}/UltiMaker-Cura-${version}-linux-modern.AppImage";
              hash = "sha256-QVv7Wkfo082PH6n6rpsB79st2xK2+Np9ivBg/PYZd74=";
            };
            extraPkgs = pkgs: with pkgs; [ ];
          };
        in
        writeScriptBin "cura" ''
          #! ${pkgs.bash}/bin/bash
          args=()
          for a in "$@"; do
            if [ -e "$a" ]; then
              a="$(realpath "$a")"
            fi
            args+=("$a")
          done
          QT_QPA_PLATFORM=xcb exec "${cura5}/bin/cura5" "''${args[@]}"
        ''
      )
    ];
  };
}
