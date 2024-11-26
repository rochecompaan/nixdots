{
  inputs,
  ...
}:
{
  imports = [
    inputs.hm.nixosModule
    # inputs.nixos-hardware.nixosModules.lenovo-thinkpad-p14s-amd-gen2
    ./hardware-configuration.nix
  ];
  networking = {
    hostName = "kipchoge";
    useDHCP = false;
    interfaces.enp10s0 = {
      ipv4.addresses = [
        {
          address = "192.168.1.4";
          prefixLength = 24;
        }
      ];
    };
    defaultGateway = "192.168.1.1";
    nameservers = [ "192.168.1.1" ];
  };

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

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = [ "nvidia" ];

}
