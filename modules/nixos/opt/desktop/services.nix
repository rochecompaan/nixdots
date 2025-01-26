{ config, lib, pkgs, ... }:
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
            command = lib.concatStringsSep " " [
              (lib.getExe pkgs.greetd.tuigreet)
              "--time"
              "--remember"
              "--remember-user-session"
              "--asterisks"
              "--sessions 'Hyprland'"
              "--cmd 'Hyprland'"
            ];
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
  };
}
