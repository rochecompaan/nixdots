{ pkgs, ... }:
{
  imports = [
    # Include the results of the hardware scan.
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

  # Set your time zone.
  time.timeZone = "Africa/Johannesburg";

  users.users.roche = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh = {
      authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHPFBvBgaJTaA+jlRSY1GzgMptcN9XHwgbCyXR/+OOvt"
      ];
    };
  };

  sops.secrets."roche_ssh_private_key" = {
    sopsFile = ../secrets/shared/roche.yaml;
    owner = "roche";
    mode = "0600";
  };

  # Sudo configuration
  security.sudo.extraRules = [
    {
      users = [ "roche" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # SSH server configuration
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  # Enable nix flakes
  nix = {
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    settings.trusted-users = [
      "root"
      "@wheel"
    ];
  };

  # Swap configuration
  swapDevices = [
    {
      device = "/swapfile";
      size = 8196; # Size in MB (8GB)
    }
  ];

  environment.systemPackages = with pkgs; [
    vim
    git
    wireguard-tools
    sops
  ];

}
