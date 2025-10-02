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
        ziti-cli = prev.stdenv.mkDerivation rec {
          pname = "ziti-cli";
          version = ziti-rev;

          src = builtins.fetchTarball {
            url = "https://github.com/openziti/ziti/releases/download/v${ziti-rev}/ziti-linux-amd64-${ziti-rev}.tar.gz";
            sha256 = "sha256:0s0lbh7cd0c4hmdiaa6cmlddri2ggx020wv3d2b34yazz2jflzfn";
          };

          installPhase = ''
            install -m755 -d $out/bin/
            install -m755 -D ./ziti $out/bin/
          '';
        };

        ziti-edge-tunnel = prev.stdenv.mkDerivation rec {
          pname = "ziti-edge-tunnel";
          version = ziti-edge-tunnel-rev;

          src = prev.fetchFromGitHub {
            owner = "openziti";
            repo = "ziti-tunnel-sdk-c";
            rev = "v${version}";
            hash = "sha256-32EbWJVhgStffvBvwexuh3mj/kK3wvk6VmkXlXtO95M=";
            leaveDotGit = true;
          };
          ziti_sdk_src = prev.fetchFromGitHub {
            owner = "openziti";
            repo = "ziti-sdk-c";
            rev = "1.8.5";
            hash = "sha256-iP6O9CEPbsqeQmPqg0Om68RUTGRobH58f6cKZ54o4ts=";
          };
          lwip_src = prev.fetchFromGitHub {
            owner = "lwip-tcpip";
            repo = "lwip";
            rev = "STABLE-2_2_1_RELEASE";
            hash = "sha256-8TYbUgHNv9SV3l203WVfbwDEHFonDAQqdykiX9OoM34=";
          };
          lwip_contrib_src = prev.fetchFromGitHub {
            owner = "netfoundry";
            repo = "lwip-contrib";
            rev = "STABLE-2_1_0_RELEASE";
            hash = "sha256-Ypn/QfkiTGoKLCQ7SXozk4D/QIdo4lyza4yq3tAoP/0=";
          };
          subcommand_c_src = prev.fetchFromGitHub {
            owner = "openziti";
            repo = "subcommands.c";
            rev = "main";
            hash = "sha256-Gz0/b9jcC1I0fmguSMkV0xiqKWq7vzUVT0Bd1F4iqkA=";
          };
          tlsuv_src = prev.fetchFromGitHub {
            owner = "openziti";
            repo = "tlsuv";
            rev = "v0.38.1";
            hash = "sha256-JTyLr1OSk2k1+EpK2IfTj9geRW0f7RIua5JkkMpcBUI=";
          };

          postPatch = ''
            # Workaround for broken llhttp package
            mkdir -p patched-cmake
            cp -r ${prev.llhttp.dev}/lib/cmake/llhttp patched-cmake/
            substituteInPlace patched-cmake/llhttp/llhttp-config.cmake \
              --replace 'set(_IMPORT_PREFIX "${prev.llhttp}")' 'set(_IMPORT_PREFIX "${prev.llhttp.dev}")'

            # Patch hardcoded paths to systemd tools
            substituteInPlace programs/ziti-edge-tunnel/netif_driver/linux/resolvers.h \
              --replace '"/usr/bin/busctl"' '"${prev.systemd}/bin/busctl"' \
              --replace '"/usr/bin/resolvectl"' '"${prev.systemd}/bin/resolvectl"' \
              --replace '"/usr/bin/systemd-resolve"' '"${prev.systemd}/bin/systemd-resolve"'
          '';

          preConfigure = ''
            # Prepend patched cmake to path
            export CMAKE_PREFIX_PATH=$(pwd)/patched-cmake''${CMAKE_PREFIX_PATH:+:}$CMAKE_PREFIX_PATH

            # Copy dependencies
            cp -r ${ziti_sdk_src} ./deps/ziti-sdk-c
            cp -r ${lwip_src} ./deps/lwip
            cp -r ${lwip_contrib_src} ./deps/lwip-contrib
            cp -r ${subcommand_c_src} ./deps/subcommand.c
            cp -r ${tlsuv_src} ./deps/tlsuv
            chmod -R +w .
          '';

          cmakeFlags = [
            "-DENABLE_VCPKG=OFF"
            "-DDISABLE_SEMVER_VERIFICATION=ON"
            "-DDISABLE_LIBSYSTEMD_FEATURE=ON" # Disable direct integration to use resolvectl fallback
            "-DZITI_SDK_DIR=../deps/ziti-sdk-c"
            "-DZITI_SDK_VERSION=1.8.5"
            "-DFETCHCONTENT_SOURCE_DIR_LWIP=../deps/lwip"
            "-DFETCHCONTENT_SOURCE_DIR_LWIP-CONTRIB=../deps/lwip-contrib"
            "-DFETCHCONTENT_SOURCE_DIR_SUBCOMMAND=../deps/subcommand.c"
            "-DFETCHCONTENT_SOURCE_DIR_TLSUV=../deps/tlsuv"
            "-DDOXYGEN_OUTPUT_DIR=/tmp/doxygen"
            "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
          ];

          nativeBuildInputs = with prev; [
            cmake
            git
            openssl
            pkg-config
            libuv
            zlib
            libsodium
            protobufc
            json_c
            llhttp
          ];

          propagatedBuildInputs = with prev; [
            systemd # For the resolvectl command at runtime
          ];

          meta.main = "ziti-edge-tunnel";
        };
      })
    ];

    environment.systemPackages = with pkgs; [
      ziti-cli
      ziti-edge-tunnel
    ];

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
