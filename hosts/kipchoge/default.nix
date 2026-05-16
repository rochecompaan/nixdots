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
  desktop = {
    enable = true;
    de = "niri";
  };

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

  environment.systemPackages = with pkgs; [
    fuse3
    rclone
  ];

  sops.secrets.copyparty = {
    owner = "roche";
    group = "users";
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d /home/roche/mnt 0755 roche users - -"
    "d /home/roche/mnt/copyparty 0755 roche users - -"
    "d /home/roche/.cache/rclone/copyparty 0700 roche users - -"
  ];

  systemd.services.rclone-copyparty = {
    description = "Mount Copyparty WebDAV";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.fuse3 ];

    script = ''
      password="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.copyparty.path})"
      obscured_password="$(${pkgs.rclone}/bin/rclone obscure "$password")"

      umask 077
      ${pkgs.coreutils}/bin/cat > "$RUNTIME_DIRECTORY/rclone.conf" <<EOF
      [copyparty]
      type = webdav
      url = https://copyparty.compaan
      vendor = owncloud
      pacer_min_sleep = 0.01ms
      user = k
      pass = $obscured_password
      EOF

      exec ${pkgs.rclone}/bin/rclone mount copyparty: /home/roche/mnt/copyparty \
        --config "$RUNTIME_DIRECTORY/rclone.conf" \
        --vfs-cache-mode writes \
        --dir-cache-time 5s \
        --cache-dir /home/roche/.cache/rclone/copyparty
    '';

    serviceConfig = {
      User = "roche";
      Group = "users";
      RuntimeDirectory = "rclone-copyparty";
      RuntimeDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "10s";
      ExecStop = "${pkgs.fuse3}/bin/fusermount3 -u /home/roche/mnt/copyparty";
    };
  };

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
