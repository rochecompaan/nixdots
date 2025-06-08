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
      cura-appimage
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

    ];
  };
}
