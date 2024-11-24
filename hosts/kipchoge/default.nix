{
  config,
  inputs,
  lib,
  ...
}:
{
  imports = [
    inputs.hm.nixosModule
    # inputs.nixos-hardware.nixosModules.lenovo-thinkpad-p14s-amd-gen2
    ./hardware-configuration.nix
  ];
  networking.hostName = "kipchoge";

  tailscale.enable = true;
  fonts.enable = true;
  wayland.enable = true;
  pipewire.enable = true;
  steam.enable = false;
  tpm.enable = true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "yes";
  };

  services.duckdns.domains = [
    "roche"
    "kipchoge"
  ];

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
  };

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = lib.mkForce false;
    powerManagement.finegrained = lib.mkForce false;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
}
