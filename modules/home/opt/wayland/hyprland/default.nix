{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf;

  _ = lib.getExe;

  # OCR (Optical Character Recognition) utility
  ocrScript =
    let
      inherit (pkgs)
        grim
        libnotify
        slurp
        tesseract5
        wl-clipboard
        ;
    in
    pkgs.writeShellScriptBin "wl-ocr" ''
      ${_ grim} -g "$(${_ slurp})" -t ppm - | ${_ tesseract5} - - | ${wl-clipboard}/bin/wl-copy
      ${_ libnotify} "$(${wl-clipboard}/bin/wl-paste)"
    '';

  # Volume control utility
  volumectl =
    let
      inherit (pkgs) libnotify pamixer libcanberra-gtk3;
    in
    pkgs.writeShellScriptBin "volumectl" ''
      #!/usr/bin/env bash

      case "$1" in
      up)
        ${_ pamixer} -i "$2"
        ;;
      down)
        ${_ pamixer} -d "$2"
        ;;
      toggle-mute)
        ${_ pamixer} -t
        ;;
      esac

      volume_percentage="$(${_ pamixer} --get-volume)"
      isMuted="$(${_ pamixer} --get-mute)"

      if [ "$isMuted" = "true" ]; then
        ${libnotify}/bin/notify-send --transient \
          -u normal \
          -a "VOLUMECTL" \
          -i audio-volume-muted-symbolic \
          "VOLUMECTL" "Volume Muted"
      else
        ${libnotify}/bin/notify-send --transient \
          -u normal \
          -a "VOLUMECTL" \
          -h string:x-canonical-private-synchronous:volumectl \
          -h int:value:"$volume_percentage" \
          -i audio-volume-high-symbolic \
          "VOLUMECTL" "Volume: $volume_percentage%"

        ${libcanberra-gtk3}/bin/canberra-gtk-play -i audio-volume-change -d "volumectl"
      fi
    '';

  # Brightness control utility
  lightctl =
    let
      inherit (pkgs) libnotify brightnessctl;
    in
    pkgs.writeShellScriptBin "lightctl" ''
      case "$1" in
      up)
        ${_ brightnessctl} -q s +"$2"%
        ;;
      down)
        ${_ brightnessctl} -q s "$2"%-
        ;;
      esac

      brightness_percentage=$((($(${_ brightnessctl} g) * 100) / $(${_ brightnessctl} m)))
      ${libnotify}/bin/notify-send --transient \
        -u normal \
        -a "LIGHTCTL" \
        -h string:x-canonical-private-synchronous:lightctl \
        -h int:value:"$brightness_percentage" \
        -i display-brightness-symbolic \
        "LIGHTCTL" "Brightness: $brightness_percentage%"
    '';
in
{
  imports = [ ./config ];

  config = mkIf (config.default.de == "hyprland") {
    home = {
      packages = with pkgs; [
        config.wayland.windowManager.hyprland.package

        autotiling-rs
        brightnessctl
        cliphist
        dbus
        glib
        grim
        gtk3
        hyprpicker
        keymapp
        libcanberra-gtk3
        libnotify
        libreoffice
        obs-studio
        qbittorrent-cli
        qbittorrent-enhanced
        sassc
        ssh-to-age
        signal-desktop
        slurp
        transmission_4
        wf-recorder
        wl-clipboard
        wl-screenrec
        wlr-randr
        wlr-randr
        wtype
        kdePackages.xwaylandvideobridge
        ydotool
        wlprop
        xorg.xprop

        ocrScript
        volumectl
        lightctl
      ];

      sessionVariables = {
        QT_QPA_PLATFORM = "wayland";
        QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
        SDL_VIDEODRIVER = "wayland";
        CLUTTER_BACKEND = "wayland";
        MOZ_ENABLE_WAYLAND = "1";
        QT_STYLE_OVERRIDE = lib.mkForce "kvantum";
        XCURSOR_SIZE = "24";
        ELECTRON_OZONE_PLATFORM_HINT = "auto";
        LIBVA_DRIVER_NAME = "nvidia";
        __GLX_VENDOR_LIBRARY_NAME = "nvidia";
        XDG_SESSION_TYPE = "wayland";
        NVD_BACKEND = "direct";
        GBM_BACKEND = "nvidia-drm";
        WLR_NO_HARDWARE_CURSORS = "1";
        NIXOS_OZONE_WL = "1";
      };
    };

    wayland.windowManager.hyprland = {
      plugins = [
        #inputs.hyprspace.packages.${pkgs.system}.Hyprspace
        #inputs.hyprsplit.packages.${pkgs.system}.hyprsplit
        #inputs.split-monitor-workspaces.packages.${pkgs.system}.split-monitor-workspaces
      ];
      xwayland.enable = true;
      enable = true;
      systemd = {
        enable = true;
        extraCommands = lib.mkBefore [
          "systemctl --user stop graphical-session.target"
          "systemctl --user start hyprland-session.target"
        ];
      };
    };

    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = [ "graphical-session-pre.target" ];
      };
    };
  };
}
