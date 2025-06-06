{ lib, ... }:
{
  wayland.windowManager.hyprland.settings = {
    # monitor rules
    monitor = [
      "HDMI-A-1,preferred,auto,1"
      "eDP-1,preferred,auto,1"
      # https://github.com/hyprwm/hyprlock/issues/434#issuecomment-2323347005
      "FALLBACK,1920x1080@60,auto,1"
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
      "stayfocused, class:zoom, title:menu window"
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
      "float, class:^(qalculate-gtk)$"
      "float, class:^(xdg-desktop-portal-gtk)$"
      "float, title:^(Media viewer)$"
      "float, title:^(Picture-in-Picture)$"
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
