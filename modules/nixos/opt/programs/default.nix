{ pkgs, ... }:
{
  programs = {
    thunar = {
      enable = true;
      plugins = with pkgs.xfce; [
        thunar-archive-plugin
        thunar-media-tags-plugin
        thunar-volman
      ];
    };
    zsh.enable = true;
    dconf.enable = true;
    wshowkeys.enable = true;
    openvpn3.enable = true;
    seahorse.enable = true; # keyring graphical frontend
    _1password-cli.enable = true;
    _1password-gui = {
      enable = true;
      # Certain features, including CLI integration and system authentication support,
      # require enabling PolKit integration on some desktop environments (e.g. Plasma).
      polkitPolicyOwners = [ "roche" ];
    };
  };
  imports = [ ./steam.nix ];
}
