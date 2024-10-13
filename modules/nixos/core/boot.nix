{
  boot = {
    kernel.sysctl."net.isoc" = true;
    loader = {
      systemd-boot = {
        enable = true;
        consoleMode = "max";
      };
      efi.canTouchEfiVariables = true;
      efi.efiSysMountPoint = "/boot";
    };
  };
}
