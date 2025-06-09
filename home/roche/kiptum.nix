{ inputs, pkgs, ... }:
{
  theme = "tokyonight";

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
    launcher = {
      anyrun.enable = true;
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
    claude-code.enable = true;
  };

  default = {
    de = "hyprland";
    terminal = "kitty";
  };

  wayland.windowManager.hyprland.settings = {
    monitor = [
      "eDP-1, 1920x1080@165, auto, auto"
      "HDMI-A-1, 1920x1080@74.97, auto, auto"
    ];
  };

  home = {
    packages = with pkgs; [
      android-tools
      vesktop
      scrcpy
      stremio
      yazi
      wdisplays
    ];
  };
}
