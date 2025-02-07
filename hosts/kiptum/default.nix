{ pkgs, inputs, ... }:
{
  imports = [
    inputs.hm.nixosModule
    inputs.nixos-hardware.nixosModules.asus-zephyrus-ga402x-nvidia
    ./hardware-configuration.nix
  ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  networking.hostName = "kiptum";
  networking.hosts = {
    "192.168.1.4" = [
      "sidecar"
      "sidecar.local"
      "kipchoge"
    ];
  };

  fonts.enable = true;
  wayland.enable = true;
  pipewire.enable = true;
  desktop.enable = true;

  services.duckdns = {
    enable = true;
    domains = [
      "rochelaptop"
    ];
  };

}
