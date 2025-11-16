{
  inputs,
  ...
}:
{
  theme = "gruvbox";

  imports = [
    inputs.stylix.homeModules.stylix
    inputs.krewfile.homeManagerModules.krewfile
    ../../modules/home
    ../desktop.nix
  ];

  # Base profile already enables zsh, gpg-agent. Keep fish override.
  modules.fish.enable = false;

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

  programs.element-desktop.enable = true;

}
