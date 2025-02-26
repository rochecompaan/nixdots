{
  systemd.network.enable = true;

  # Enable SSH with root login
  services.openssh = {
    enable = true;
    permitRootLogin = "yes";
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHPFBvBgaJTaA+jlRSY1GzgMptcN9XHwgbCyXR/+OOvt"
  ];
}
