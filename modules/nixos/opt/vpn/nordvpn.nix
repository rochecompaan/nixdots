{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.vpn.nordvpn.enable = lib.mkEnableOption "Enable NordVPN";

  config = lib.mkIf config.vpn.nordvpn.enable {
    sops.secrets."nordvpn-login" = { };

    environment.etc."openvpn/se491.nordvpn.com.udp.ovpn".source = pkgs.fetchurl {
      url = "https://downloads.nordcdn.com/configs/files/ovpn_udp/servers/se491.nordvpn.com.udp.ovpn";
      hash = "sha256-B7FPAbViCoW0vdzvO0TLKzxyyFOpZcCvKOB7alDHWes=";
    };

    services.openvpn.servers = {
      nordvpn-sweden-vpn = {
        autoStart = false;
        config = ''
          config ${config.environment.etc."openvpn/se491.nordvpn.com.udp.ovpn".source}
          auth-user-pass ${config.sops.secrets."nordvpn-login".path}
        '';
        updateResolvConf = true;
      };
    };
  };
}
