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
  options.desktop = {
    enable = lib.mkEnableOption "Desktop configuration";
  };

  config = lib.mkIf cfg.enable {
    hardware = {
      bluetooth.enable = true;
      bluetooth.input.General = {
        ClassicBondedOnly = false;
      };
      bluetooth.powerOnBoot = true;
      graphics = {
        enable = true;
        enable32Bit = true;
      };
      gpgSmartcards.enable = true;
      ledger.enable = true;
      nvidia.open = false;
      nvidia.powerManagement = {
        enable = true;
        finegrained = true;
      };
      keyboard.qmk.enable = true;
    };

    programs = {
      thunar = {
        enable = true;
        plugins = with pkgs.xfce; [
          thunar-archive-plugin
          thunar-media-tags-plugin
          thunar-volman
        ];
      };
      dconf.enable = true;
      wshowkeys.enable = true;
      openvpn3.enable = true;
      seahorse.enable = true;
      _1password.enable = true;
      _1password-gui = {
        enable = true;
        polkitPolicyOwners = [ "roche" ];
      };
      steam = lib.mkIf config.steam.enable {
        enable = true;
        remotePlay.openFirewall = true;
        dedicatedServer.openFirewall = true;
      };
    };

    services = {
      xserver.enable = false;
      asusd = {
        enable = true;
        enableUserService = true;
      };
      blueman.enable = true;
      dbus.enable = true;
      upower.enable = true;
      # automount disks with devmon, gvfs and udisks2
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
