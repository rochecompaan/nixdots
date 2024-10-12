{ inputs, pkgs, ... }:
{
  theme = "decay";

  imports = [
    inputs.stylix.homeManagerModules.stylix
    inputs.anyrun.homeManagerModules.default
    ../../modules/home
  ];
  opt = {
    browser = {
      firefox.enable = true;
    };
    misc = {
      obsidian.enable = true;
      yamlfmt.enable = true;
      rbw.enable = true;
    };
    music = {
      spicetify.enable = true;
    };
    launcher = {
      anyrun.enable = true;
    };
    lock = {
      hyprlock.enable = true;
    };
    services = {
      cliphist.enable = true;
      hypridle.enable = true;
      hyprpaper.enable = true;
      kanshi.enable = true;
      # swaync.enable = true;
      # waybar.enable = true;
      ags.enable = true;

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
    zsh.enable = true;
    gpg-agent.enable = true;
  };

  default = {
    de = "hyprland";
    terminal = "foot";
  };

  home = {
    packages = with pkgs; [
      teeworlds # very important to work
    ];
  };
}
