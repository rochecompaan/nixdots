{ config, lib, ... }:
{
  imports = [
    ./disko.nix
    ./hardware-configuration.nix
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking = {
    hostName = "dauwalter";
    interfaces = {
      eno1 = {
        ipv4 = {
          addresses = [
            {
              address = "192.168.1.100";
              prefixLength = 24;
            }
          ];
        };
      };
    };
    defaultGateway = "192.168.1.1";
    nameservers = [ "192.168.1.1" ];
  };

  # https://nixos.org/manual/nixos/stable/#sec-custom-ifnames
  # alias network interface to ensure kube-vip interface name is consistent
  systemd.network.links."10-rename-interface" = {
    matchConfig.PermanentMACAddress = "f0:a7:31:b0:b5:4c";
    linkConfig.Name = "eno1";
  };

  # Swap configuration
  swapDevices = [
    {
      device = "/swapfile";
      size = 8196; # Size in MB (8GB)
    }
  ];

  # Disable suspend on lid close
  services.logind = {
    lidSwitch = "ignore";
    settings = {
      Login = {
        HandleLidSwitch = "ignore";
      };
    };
  };

  # disable sleep
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

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
    clusterInit = true;
    role = "server";
    tokenFile = config.sops.secrets."cluster-token".path;

    extraFlags = lib.concatStringsSep " " [
      "--node-ip=192.168.1.100"
      "--disable=traefik"
      "--disable=servicelb"
      "--tls-san=192.168.1.100"
      "--tls-san=192.168.1.200" # kube-vip VIP
      "--tls-san=kubernetes.compaan.cloud"
      "--write-kubeconfig-mode=0644"
    ];

    manifests = {
      argocd.content = {
        apiVersion = "helm.cattle.io/v1";
        kind = "HelmChart";
        metadata = {
          name = "argocd";
          namespace = "kube-system";
        };
        spec = {
          targetNamespace = "argocd";
          createNamespace = true;
          repo = "https://argoproj.github.io/argo-helm";
          chart = "argo-cd";
          version = "9.1.4";
          valuesContent = ''
            configs:
              params:
                server.insecure: true
          '';
        };
      };
    };
  };
}
