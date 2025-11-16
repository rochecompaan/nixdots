{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf;
in
{
  config = mkIf config.default.isDesktop {
    home.packages =
      with pkgs;
      [
        android-tools
        keymapp
        libreoffice
        obs-studio
        qbittorrent-cli
        qbittorrent-enhanced
        scrcpy
        signal-desktop
        ssh-to-age
        stremio
        stretchly
        transmission_4
        vesktop
        wdisplays
        wlprop
        xorg.xprop
        yazi
        ydotool
      ]
      ++ (with inputs.nix-ai-tools.packages.${pkgs.system}; [
        codex
        claude-code
        claude-code-router
        opencode
        gemini-cli
        goose-cli
      ]);

  };
}
