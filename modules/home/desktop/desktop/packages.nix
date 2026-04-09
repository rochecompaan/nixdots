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
        copier
        gimp
        keymapp
        libreoffice
        nextcloud-client
        obs-studio
        playwright-test
        playwright-mcp
        qbittorrent-cli
        qbittorrent-enhanced
        scrcpy
        signal-desktop
        ssh-to-age
        stremio
        timewarrior
        transmission_4
        vesktop
        vlc
        wdisplays
        wlprop
        xorg.xprop
        yazi
        ydotool
      ]
      ++ (with inputs.llm-agents.packages.${pkgs.system}; [
        codex
        claude-code
        gemini-cli
        pi
      ]);

  };
}
