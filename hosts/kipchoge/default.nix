{
  config,
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    inputs.hm.nixosModules.default
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
    hosts = {
      "127.0.0.1" = [
        "www.emas"
        "m.emas"
        "mailhog.emas"
        "minio.emas"
      ];
    };
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
    nameservers = [
      "100.64.0.2"
      "192.168.1.1"
    ];
  };

  fonts.enable = true;
  wayland.enable = true;
  pipewire.enable = true;
  desktop.enable = true;

  vpn.nordvpn.enable = true;
  vpn.sfu.enable = true;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  services.flatpak.enable = true;

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
  services.resolved.enable = true;

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

  services.jellyfin.enable = true;
  environment.systemPackages = with pkgs; [
    jellyfin
    jellyfin-web
    jellyfin-ffmpeg
  ];

  services.duckdns = {
    enable = true;
    domains = [
      "roche"
    ];
    tokenFile = config.sops.secrets."duckdns-token".path;
  };

  programs.ziti = {
    enable = true;
  };

  programs.ziti-edge-tunnel = {
    enable = true;
    service.enable = true;
  };

  programs.adb.enable = true;

  fileSystems."/mnt/kipsang-data" = {
    device = "192.168.1.101:/";
    fsType = "nfs";
  };

}
