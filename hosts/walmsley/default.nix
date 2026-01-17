{
  config,
  lib,
  inputs,
  ...
}:
{
  imports = [
    ./disko.nix
    ./hardware-configuration.nix
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking = {
    hostName = "walmsley";
    interfaces = {
      eno1 = {
        ipv4 = {
          addresses = [
            {
              address = "192.168.1.103";
              prefixLength = 24;
            }
          ];
        };
      };
    };
    defaultGateway = "192.168.1.1";
    nameservers = [ "192.168.1.1" ];
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 8196;
    }
  ];

  services.openiscsi = {
    enable = true;
    name = "iqn.2025-12.compaan.cloud:homelab";
  };
  systemd.services.iscsid.serviceConfig = {
    PrivateMounts = "yes";
    BindPaths = "/run/current-system/sw/bin:/bin";
  };

  # homelab.k3s.reset.enable = true;

  services.k3s = {
    enable = true;
    role = "server";
    serverAddr = "https://192.168.1.100:6443"; # XXX: Change to load balancer address
    tokenFile = config.sops.secrets."cluster-token".path;

    extraFlags = lib.concatStringsSep " " [
      "--node-ip=192.168.1.103"
      "--disable=traefik"
      "--disable=service-lb"
      "--tls-san=kubernetes.compaan"
      "--write-kubeconfig-mode=0644"
    ];
  };

  programs.ziti-edge-tunnel = {
    enable = true;
    service.enable = true;
    enrollment = {
      enable = true;
      jwtFile = config.sops.secrets."ziti-token".path;
      identityFile = "/opt/openziti/etc/identities/host-identity.json";
    };
  };

  sops = {
    secrets = {
      "ziti-token" = {
        key = "ziti-${config.networking.hostName}";
        sopsFile = "${inputs.nix-secrets}/secrets.yaml";
      };
    };
  };
}
