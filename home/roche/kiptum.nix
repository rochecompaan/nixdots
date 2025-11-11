{ inputs, pkgs, ... }:
{
  theme = "gruvbox";

  imports = [
    inputs.stylix.homeModules.stylix
    inputs.krewfile.homeManagerModules.krewfile
    ../../modules/home
  ];

  opt = {
    browser = {
      firefox.enable = true;
    };
    misc = {
      obsidian.enable = true;
      yamlfmt.enable = true;
    };
    lock = {
      hyprlock.enable = true;
    };
    services = {
      ags.enable = true;
      cliphist.enable = true;
      hypridle = {
        enable = true;
        enableSuspend = true;
      };
      hyprpaper.enable = true;
      kanshi.enable = true;
      #swaync.enable = true;
      waybar.enable = true;
      glance.enable = true;
    };
    utils = {
      rofi.enable = true;
      lazygit.enable = true;
      k9s.enable = true;
    };
    shell = {
      zellij.enable = true;
    };
  };

  modules = {
    aider.enable = true;
    zsh.enable = true;
    gpg-agent.enable = true;
  };

  default = {
    de = "hyprland";
    terminal = "kitty";
  };

  wayland.windowManager.hyprland.settings = {
    monitor = [
      "HDMI-A-1, 1920x1080@74.97, 0x0, auto"
      "eDP-1, 1920x1080@165, 1920x0, auto"
    ];
  };

  home = {
    packages =
      with pkgs;
      [
        android-tools
        vesktop
        scrcpy
        stremio
        yazi
        wdisplays
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
