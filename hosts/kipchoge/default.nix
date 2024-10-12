{ inputs, ... }:
{
  imports = [
    inputs.hm.nixosModule
    # inputs.nixos-hardware.nixosModules.lenovo-thinkpad-p14s-amd-gen2
    ./hardware-configuration.nix
  ];
  networking.hostName = "kipchoge";

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
