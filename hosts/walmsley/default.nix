{
  imports = [
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

  # Swap configuration
  swapDevices = [
    {
      device = "/swapfile";
      size = 8196; # Size in MB (8GB)
    }
  ];
}
