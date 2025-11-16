{ inputs, ... }:
{
  theme = "gruvbox";

  imports = [
    inputs.stylix.homeModules.stylix
    inputs.krewfile.homeManagerModules.krewfile
    ../../modules/home
    ../../modules/home/desktop
  ];

  home.sessionVariables.TERMINAL = "foot";

  default = {
    de = "niri";
    terminal = "kitty";
  };

  # Idle suspend after 30 minutes
  services.hypridle.settings.listener = [
    {
      timeout = 1800;
      on-timeout = "systemctl suspend";
    }
  ];

  wayland.windowManager.hyprland.settings = {
    monitor = [
      "HDMI-A-1, 1920x1080@74.97, 0x0, auto"
      "eDP-1, 1920x1080@165, 1920x0, auto"
    ];

    # workspace rules
    workspace = [
      "1,monitor:HDMI-A-1"
      "2,monitor:HDMI-A-1"
      "3,monitor:HDMI-A-1"
      "4,monitor:HDMI-A-1"
      "5,monitor:HDMI-A-1"
      "6,monitor:HDMI-A-1"
      "7,monitor:HDMI-A-1"
      "8,monitor:eDP-1"
      "9,monitor:eDP-1"
      "10,monitor:eDP-1"
    ];
  };

}
