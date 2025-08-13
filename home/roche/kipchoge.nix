{
  inputs,
  pkgs,
  ...
}:
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
      zen.enable = true;
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
      hypridle.enable = true;
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
    goose-cli.enable = true;
  };

  default = {
    de = "hyprland";
    terminal = "kitty";
  };

  wayland.windowManager.hyprland.settings = {
    monitor = [
      "DP-1, 3840x2160@60, auto, 2"
      "HDMI-A-1, 3840x2160@60, auto, 2"
    ];

    # workspace rules
    workspace = [
      "1,monitor:HDMI-A-1"
      "2,monitor:HDMI-A-1"
      "3,monitor:HDMI-A-1"
      "4,monitor:HDMI-A-1"
      "5,monitor:HDMI-A-1"
      "6,monitor:DP-1"
      "7,monitor:DP-1"
      "8,monitor:DP-1"
      "9,monitor:DP-1"
      "10,monitor:DP-1"
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
        claude-code
        opencode
        gemini-cli
        qwen-code
      ]);
  };
}
