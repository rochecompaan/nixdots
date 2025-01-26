{ config, lib, pkgs, ... }:
let
  cfg = config.desktop;
in
{
  config = lib.mkIf cfg.enable {
    programs = {
      thunar = {
        enable = true;
        plugins = with pkgs.xfce; [
          thunar-archive-plugin
          thunar-media-tags-plugin
          thunar-volman
        ];
      };
      dconf.enable = true;
      wshowkeys.enable = true;
      openvpn3.enable = true;
      seahorse.enable = true;
      _1password.enable = true;
      _1password-gui = {
        enable = true;
        polkitPolicyOwners = [ "roche" ];
      };
      steam = lib.mkIf config.steam.enable {
        enable = true;
        remotePlay.openFirewall = true;
        dedicatedServer.openFirewall = true;
      };
    };
  };
}
