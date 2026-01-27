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

  # Turn off screen backlight when lid closes
  services.acpid = {
    enable = true;
    lidEventCommands = ''
      if grep -q closed /proc/acpi/button/lid/*/state; then
        for backlight in /sys/class/backlight/*; do
          [ -d "$backlight" ] && echo 0 > "$backlight/brightness"
        done
      else
        for backlight in /sys/class/backlight/*; do
          [ -d "$backlight" ] && cat "$backlight/max_brightness" > "$backlight/brightness"
        done
      fi
    '';
  };

  # Check lid state on boot and turn off backlight if closed
  systemd.services.lid-backlight-boot = {
    description = "Turn off backlight on boot if lid is closed";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if grep -q closed /proc/acpi/button/lid/*/state 2>/dev/null; then
        for backlight in /sys/class/backlight/*; do
          [ -d "$backlight" ] && echo 0 > "$backlight/brightness"
        done
      fi
    '';
  };

  # disable sleep
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

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
      "--disable=local-storage"
      "--disable=traefik"
      "--disable=servicelb"
      "--tls-san=192.168.1.100"
      "--tls-san=192.168.1.200" # kube-vip VIP
      "--tls-san=kubernetes.compaan"
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
