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
      asusd.enable = true;
      blueman.enable = true;
      dbus = {
        enable = true;
        packages = [ pkgs.dconf ];
      };
      upower.enable = true;
      devmon.enable = true;
      gvfs.enable = true;
      udisks2.enable = true;
      logind.settings.Login = {
        HandlePowerKey = "suspend";
        HandleLidSwitch = "suspend";
        HandleLidSwitchExternalPower = "lock";
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
                sessionCommand =
                  if config.desktop.de == "hyprland" then
                    "hyprland"
                  else if config.desktop.de == "niri" then
                    "niri-session"
                  else
                    "";
              in
              lib.escapeShellArgs [
                (lib.getExe pkgs.tuigreet)
                "--time"
                "--remember"
                "--asterisks"
                "--cmd"
                sessionCommand
              ];
            user = "greeter";
          };
        };
      };
      udev = {
        packages = [
          pkgs.libu2f-host
          pkgs.yubikey-personalization
          pkgs.platformio-core.udev
          pkgs.openocd
        ];
        extraRules = ''
          # pcscd runs unprivileged as the pcscd user/group. The upstream CCID
          # rule sets GROUP="pcscd" but leaves the device mode at the default,
          # which can produce ACLs where group::--- prevents pcscd from opening
          # YubiKey/OpenPGP CCID devices after uaccess is applied.
          ACTION=="add|change", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_USB_INTERFACES}=="*:0b0000:*", GROUP="pcscd", MODE="0660"
        '';
      };
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
