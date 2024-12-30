{ config, pkgs, ... }:
{
  sops.secrets.roche-password = {
    neededForUsers = true;
  };
  users = {
    users.roche = {
      hashedPasswordFile = config.sops.secrets.roche-password.path;
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "networkmanager"
        "audio"
        "video"
        "libvirtd"
        "docker"
        "uinput"
        "adbusers"
      ];
      openssh = {
        authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHPFBvBgaJTaA+jlRSY1GzgMptcN9XHwgbCyXR/+OOvt"
        ];
      };
    };
    defaultUserShell = pkgs.zsh;
  };
}
