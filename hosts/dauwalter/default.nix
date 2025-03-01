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
      enp0s20f0u2 = {
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
    lidSwitchDocked = "ignore";
    lidSwitchExternalPower = "ignore";
    extraConfig = ''
      HandleSuspendKey=ignore
      HandleHibernateKey=ignore
    '';
  };

  # Ensure the system doesn't go to sleep automatically
  powerManagement = {
    enable = true;
    powertop.enable = false;
    cpuFreqGovernor = "performance";
  };
}
