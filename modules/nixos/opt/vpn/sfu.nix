{
  config,
  lib,
  inputs,
  ...
}:
{
  options.vpn.sfu.enable = lib.mkEnableOption "Enable SFU VPN";

  config = lib.mkIf config.vpn.sfu.enable {
    sops.secrets."ovpn.conf" = {
      sopsFile = "${inputs.nix-secrets}/sfu-vpn.yaml";
    };

    services.openvpn.servers = {
      sfu-vpn = {
        autoStart = false;
        config = ''
          config ${config.sops.secrets."ovpn.conf".path}
        '';
        updateResolvConf = true;
      };
    };
  };
}
