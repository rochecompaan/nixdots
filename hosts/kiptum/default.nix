{ pkgs, inputs, ... }:
{
  imports = [
    inputs.hm.nixosModule
    inputs.nixos-hardware.nixosModules.asus-zephyrus-ga402x-nvidia
    ./hardware-configuration.nix
  ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  networking.hostName = "kiptum";
  networking.hosts = {
    "192.168.1.4" = [
      "sidecar"
      "sidecar.local"
      "kipchoge"
    ];
  };

  tailscale.enable = true;
  fonts.enable = true;
  wayland.enable = true;
  pipewire.enable = true;
  steam.enable = false;
  tpm.enable = true;
}
