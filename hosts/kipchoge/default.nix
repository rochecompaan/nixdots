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

  nix = {
    settings = {
      # Resource management settings
      max-jobs = 8; # Limit parallel build jobs
      cores = 8; # Cores per build job
      min-free = "2G"; # Keep at least 2GB free
    };
  };

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

  services.mosquitto = {
    enable = true;
    listeners = [
      {
        address = "192.168.1.4";
        port = 1883;
        acl = [ "pattern readwrite #" ];
        omitPasswordAuth = true;
        settings.allow_anonymous = true;
      }
    ];
  };

  virtualisation.oci-containers = {
    backend = "docker";
    containers.homeassistant = {
      volumes = [ "/home/roche/home-assistant:/config" ];
      environment.TZ = "Africa/Johannesburg";
      # Warning: if the tag does not change, the image will not be updated
      image = "ghcr.io/home-assistant/home-assistant:stable";
      autoStart = true;
      extraOptions = [
        "--privileged"
        "--network=host"
      ];
    };
  };

  services.openvpn.servers = {
    urbint-vpn = {
      autoStart = false;
      config = ''config /home/roche/.config/openvpn/urbint.ovpn '';
      updateResolvConf = true;
    };
    sfu-vpn = {
      autoStart = false;
      config = ''config /home/roche/.config/openvpn/sfu.ovpn '';
      updateResolvConf = true;
    };
  };
}
