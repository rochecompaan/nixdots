{
  config,
  inputs,
  ...
}:
{
  imports = [
    inputs.hm.nixosModules.default
    ./hardware-configuration.nix
  ];

  nix = {
    settings = {
      # Resource management settings: avoid memory-pressure stalls during large builds.
      max-jobs = 2; # Limit parallel build jobs
      cores = 8; # Cores per build job
      min-free = "5G"; # Keep enough headroom for the desktop and OOM handling
    };
  };

  # Add breathing room for memory spikes from browsers, containers, and compilers.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 32768; # MiB
    }
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
    priority = 100;
  };

  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableSystemSlice = true;
    enableUserSlices = true;
    settings.OOM = {
      DefaultMemoryPressureDurationSec = "20s";
      DefaultMemoryPressureLimit = "60%";
      SwapUsedLimit = "90%";
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
    enable = false;
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

  # systemd.services.ziti-edge-tunnel.environment = {
  #   ZITI_VERBOSE = "trace";
  #   ZITI_LOG = "6;tlsuv=6";
  #   TLS_DEBUG = "1";
  # };

  programs.adb.enable = true;

  services.caddy = {
    enable = true;
    config = ''
      :8096 {
        reverse_proxy https://jellyfin.compaan {
          header_up Host jellyfin.compaan
        }
      }
    '';
  };

  # Temporary MQTT proxy until client IPs can be updated
  services.haproxy = {
    enable = true;
    config = ''
      frontend mqtt
        bind *:1883
        mode tcp
        default_backend mqtt_backend

      backend mqtt_backend
        mode tcp
        server mqtt 192.168.1.1:1883
    '';
  };

  fileSystems."/mnt/kipsang-data" = {
    device = "192.168.1.101:/";
    fsType = "nfs";
  };

}
