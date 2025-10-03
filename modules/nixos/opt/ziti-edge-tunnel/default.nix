{
  lib,
  config,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.programs.ziti-edge-tunnel;
in
{
  options.programs.ziti-edge-tunnel = {
    enable = mkEnableOption "Ziti Edge Tunnel";
    tunnel.enable = mkEnableOption "Ziti Edge Tunnel service";
  };

  config = mkIf cfg.enable {
    nixpkgs.overlays = [
      (_: prev: {
        ziti-edge-tunnel = prev.callPackage ./package.nix { };
      })
    ];

    environment.systemPackages = [ pkgs.ziti-edge-tunnel ];

    systemd.services.ziti-edge-tunnel = mkIf cfg.tunnel.enable {
      description = "Ziti Edge Tunnel";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.ziti-edge-tunnel}/bin/ziti-edge-tunnel run -I /opt/openziti/etc/identities";
        Restart = "on-failure";
        Environment = [ "ZITI_LOG=6;tlsuv=6" ];
      };
    };
  };
}
