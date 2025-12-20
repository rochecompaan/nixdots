{
  config,
  lib,
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
    hostName = "kipsang";
    interfaces = {
      eno1 = {
        ipv4 = {
          addresses = [
            {
              address = "192.168.1.101";
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
      "--node-ip=192.168.1.101"
      "--disable=traefik"
      "--disable=service-lb"
      "--tls-san=kubernetes.compaan.cloud"
      "--write-kubeconfig-mode=0644"
    ];
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/data/kipchoge 192.168.1.4(rw,async,insecure,no_subtree_check,fsid=0)
    '';
  };

  systemd.tmpfiles.rules = [
    "d /srv/data/kipchoge 0775 roche users -"
  ];

}
