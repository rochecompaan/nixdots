{ pkgs, ... }:
{
  users = {
    users.roche = {
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
