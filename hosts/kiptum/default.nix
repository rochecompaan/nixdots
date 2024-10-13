{ inputs, ... }:
{
  imports = [
    inputs.hm.nixosModule
    inputs.nixos-hardware.nixosModules.asus-zephyrus-ga402x-nvidia
    ./hardware-configuration.nix
  ];
  networking.hostName = "kiptum";
  networking.hosts = {
    "192.168.1.4" = [ "sidecar" "sidecar.local" "kipchoge" ];
  };

  opt = {
    services = {
      xserver.enable = true;
    };
  };

  tailscale.enable = true;
  fonts.enable = true;
  wayland.enable = true;
  pipewire.enable = true;
  steam.enable = false;
  tpm.enable = true;
}
