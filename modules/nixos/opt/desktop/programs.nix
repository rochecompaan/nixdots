{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.desktop;
in
{
  config = lib.mkIf cfg.enable {
    programs = {
      thunar = {
        enable = true;
        plugins = with pkgs; [
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
      _1password-shell-plugins = {
        # enable 1Password shell plugins for bash, zsh, and fish shell
        enable = true;
        # the specified packages as well as 1Password CLI will be
        # automatically installed and configured to use shell plugins
        plugins = with pkgs; [
          gh
          awscli2
          cachix
        ];
      };
    }
    // lib.optionalAttrs (cfg.de == "niri") {
      niri.enable = true;
    };
  };
}
