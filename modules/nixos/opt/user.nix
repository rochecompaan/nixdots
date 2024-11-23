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
    };
    defaultUserShell = pkgs.zsh;
  };
}
