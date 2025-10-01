{
  lib,
  config,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.programs.openziti;

  ziti-rev = "1.6.8";
  ziti-edge-tunnel-rev = "1.7.12";

in
{
  options.programs.openziti = {
    enable = mkEnableOption "openziti tools";
    tunnel.enable = mkEnableOption "Ziti Edge Tunnel service";
  };

  config = mkIf cfg.enable {
    nixpkgs.overlays = [
      (_: prev: {
        openziti-tools = prev.stdenv.mkDerivation rec {
          pname = "openziti-tools";
          version = ziti-rev;

          srcBinZiti = builtins.fetchTarball {
            url = "https://github.com/openziti/ziti/releases/download/v${ziti-rev}/ziti-linux-amd64-${ziti-rev}.tar.gz";
            sha256 = "sha256:0s0lbh7cd0c4hmdiaa6cmlddri2ggx020wv3d2b34yazz2jflzfn";
          };

          srcBinZitiEdgeTunnel = prev.fetchzip rec {
            version = ziti-edge-tunnel-rev;
            url = "https://github.com/openziti/ziti-tunnel-sdk-c/releases/download/v${ziti-edge-tunnel-rev}/ziti-edge-tunnel-Linux_x86_64.zip";
            hash = "sha256-dCikxZuliBhTgPEeDcYVdOhnlz7P5InhmGpxksBX0hk=";
          };

          src = srcBinZiti;

          nativeBuildInputs = with prev; [
            autoPatchelfHook
            makeWrapper
            unzip
            zlib
          ];

          runtimeDeps = with prev; [
            systemd
          ];

          installPhase = ''
            install -m755 -d $out/bin/
            install -m755 -D ./ziti $out/bin/
            install -m755 -D $srcBinZitiEdgeTunnel/ziti-edge-tunnel $out/bin/.ziti-edge-tunnel-unwrapped
            makeWrapper $out/bin/.ziti-edge-tunnel-unwrapped $out/bin/ziti-edge-tunnel \
              --set LD_LIBRARY_PATH ${prev.lib.makeLibraryPath runtimeDeps}
          '';
        };
      })
    ];

    environment.systemPackages = [ pkgs.openziti-tools ];

    systemd.services.ziti-edge-tunnel = mkIf cfg.tunnel.enable {
      description = "Ziti Edge Tunnel";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.openziti-tools}/bin/ziti-edge-tunnel run -I /opt/openziti/etc/identities";
        Restart = "on-failure";
      };
    };
  };
}
