{
  config,
  pkgs,
  inputs,
  ...
}:
{
  imports = [
    inputs.hm.nixosModules.default
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
    "127.0.0.1" = [
      "www.emas"
      "m.emas"
      "mailhog.emas"
      "minio.emas"
    ];
  };

  fonts.enable = true;
  wayland.enable = true;
  pipewire.enable = true;
  desktop.enable = true;

  vpn.nordvpn.enable = true;
  vpn.sfu.enable = true;

  services.duckdns = {
    enable = true;
    domains = [
      "rochelaptop"
    ];
    tokenFile = config.sops.secrets."duckdns-token".path;
  };

  services.resolved.enable = true;

  services.flatpak.enable = true;

  programs.ziti = {
    enable = true;
  };

  programs.ziti-edge-tunnel = {
    enable = true;
    tunnel.enable = true;
  };

}
