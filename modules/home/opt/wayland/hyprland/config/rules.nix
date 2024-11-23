{ lib, ... }:
{
  wayland.windowManager.hyprland.settings = {
    # monitor rules
    monitor = [
      "HDMI-A-1,preferred,auto,1"
      "eDP-1,preferred,auto,1"
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
      "8,monitor:HDMI-A-1"
      "9,monitor:HDMI-A-1"
      "10,monitor:eDP-1"
    ];

    # layer rules
    layerrule =
      let
        toRegex =
          list:
          let
            elements = lib.concatStringsSep "|" list;
          in
          "^(${elements})$";

        layers = [
          "anyrun"
          "gtk-layer-shell"
          "swaync-control-center"
          "swaync-notification-window"
          "waybar"
        ];
      in
      [
        "blur, ${toRegex layers}"
        "ignorealpha 0.5, ${toRegex layers}"
      ];

    plugin = {
      split-monitor-workspaces = {
        count = 5;
      };
    };

    # window rules
    windowrulev2 = [
      "dimaround, class:^(gcr-prompter)$"
      "dimaround, class:^(xdg-desktop-portal-gtk)$"
      "dimaround, class:^(polkit-gnome-authentication-agent-1)$"
      "float, class:^(clipse)$"
      "float, class:^(imv)$"
      "float, class:^(io.bassi.Amberol)$"
      "float, class:^(io.github.celluloid_player.Celluloid)$"
      "float, class:^(nm-connection-editor)$"
      "float, class:^(org.gnome.Loupe)$"
      "float, class:^(pavucontrol)$"
      "float, class:^(thunar)$"
      "float, class:^(xdg-desktop-portal-gtk)$"
      "float, title:^(Media viewer)$"
      "float, title:^(Picture-in-Picture)$"
      "float, class:^(obsidian)$"
      "idleinhibit focus, class:^(mpv|.+exe|celluloid)$"
      "idleinhibit focus, class:^(firefox)$, title:^(.*YouTube.*)$"
      "idleinhibit fullscreen, class:^(firefox)$"
      "pin, title:^(Picture-in-Picture)$"
      "workspace special silent, title:^(.*is sharing (your screen|a window).)$"
      "workspace special silent, title:^(Firefox — Sharing Indicator)$"
      "workspace special, class:^(obsidian)$"
      "workspace 2,class:^(zen-alpha)$"
      "workspace 9,class:^(Slack)$"
    ];
  };
}
