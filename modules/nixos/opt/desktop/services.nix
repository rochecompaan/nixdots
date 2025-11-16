{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.desktop;
in
{
  config = lib.mkIf cfg.enable {
    services = {
      xserver.enable = false;
      asusd = {
        enable = true;
        enableUserService = true;
      };
      blueman.enable = true;
      dbus.enable = true;
      upower.enable = true;
      devmon.enable = true;
      gvfs.enable = true;
      udisks2.enable = true;
      logind = {
        powerKey = "suspend";
        lidSwitch = "suspend";
        lidSwitchExternalPower = "lock";
      };
      pipewire = lib.mkIf config.pipewire.enable {
        enable = true;
        pulse.enable = true;
      };
      gnome = {
        gnome-keyring.enable = true;
        glib-networking.enable = true;
      };
      printing.enable = true;
      greetd = lib.mkIf config.wayland.enable {
        enable = true;
        settings = {
          terminal.vt = 1;
          default_session = {
            command =
              let
                sessionArgs =
                  if config.desktop.de == "hyprland" then
                    [
                      "--sessions 'Hyprland'"
                      "--cmd 'hyprland'"
                    ]
                  else if config.desktop.de == "niri" then
                    [
                      "--sessions 'niri'"
                      "--cmd 'niri-session'"
                    ]
                  else
                    [ ];
              in
              lib.concatStringsSep " " (
                [
                  (lib.getExe pkgs.greetd.tuigreet)
                  "--time"
                  "--remember"
                  "--remember-user-session"
                  "--asterisks"
                ]
                ++ sessionArgs
              );
            user = "greeter";
          };
        };
      };
      onedrive.enable = true;
      udev.packages = [
        pkgs.libu2f-host
        pkgs.yubikey-personalization
      ];
      pcscd.enable = true;
      supergfxd.enable = true;
      power-profiles-daemon.enable = true;
    };

    systemd.user.services.polkit-gnome-authentication-agent-1 = {
      description = "polkit-gnome-authentication-agent-1";
      wantedBy = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
    };
  };
}
