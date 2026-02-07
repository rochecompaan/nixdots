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
        gimp
        keymapp
        libreoffice
        nextcloud-client
        obs-studio
        qbittorrent-cli
        qbittorrent-enhanced
        scrcpy
        signal-desktop
        ssh-to-age
        stremio
        transmission_4
        vesktop
        vlc
        wdisplays
        wlprop
        xorg.xprop
        yazi
        ydotool
      ]
      ++ [ inputs.flox.packages.${pkgs.system}.default ]
      ++ [ inputs.kimi-cli.packages.${pkgs.system}.kimi-cli ]
      ++ (with inputs.nix-ai-tools.packages.${pkgs.system}; [
        codex
        claude-code
        claude-code-router
        opencode
        gemini-cli
      ]);

  };
}
