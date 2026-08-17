{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      ca-bundle-helper = ../../nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-ca-bundle;
      ca-bundle-test = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/ca-bundle-test.sh;
      compaan-ca = ../../modules/nixos/core/certs/compaan-ca.crt;
      dnsmasq-helper = ../../nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-dnsmasq;
      dnsmasq-helper-test = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/update-dnsmasq-test.sh;
      dnsmasq-test = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/dnsmasq-test.sh;
      validator-test = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh;
      verify-ipk = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh;
      ziti-edge-tunnel-openwrt = import ../../nix/packages/ziti-edge-tunnel-openwrt { inherit pkgs; };
    in
    {
      packages.ziti-edge-tunnel-openwrt = ziti-edge-tunnel-openwrt;
      checks.ziti-edge-tunnel-openwrt-build = ziti-edge-tunnel-openwrt;
      checks.ziti-edge-tunnel-openwrt-ca-bundle =
        pkgs.runCommand "ziti-edge-tunnel-openwrt-ca-bundle-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.busybox
              pkgs.openssl
              pkgs.util-linux
            ];
          }
          ''
            bash ${ca-bundle-test} ${ca-bundle-helper} ${compaan-ca} \
              bash "${pkgs.busybox}/bin/busybox ash"
            touch $out
          '';
      checks.ziti-edge-tunnel-openwrt-dnsmasq-helper =
        pkgs.runCommand "ziti-edge-tunnel-openwrt-dnsmasq-helper-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.busybox
              pkgs.python3
              pkgs.util-linux
            ];
          }
          ''
            bash ${dnsmasq-helper-test} ${dnsmasq-helper} \
              bash "${pkgs.busybox}/bin/busybox ash"
            touch $out
          '';
      checks.ziti-edge-tunnel-openwrt-dnsmasq-routing =
        pkgs.runCommand "ziti-edge-tunnel-openwrt-dnsmasq-routing-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.dnsmasq
              pkgs.python3
            ];
          }
          ''
            bash ${dnsmasq-test} ${pkgs.dnsmasq}/bin/dnsmasq
            touch $out
          '';
      checks.ziti-edge-tunnel-openwrt-ipk =
        pkgs.runCommand "ziti-edge-tunnel-openwrt-ipk-test"
          {
            nativeBuildInputs = [
              pkgs.binutils
              pkgs.file
              pkgs.gnutar
              pkgs.gzip
              pkgs.openssl
              pkgs.python3
              pkgs.xz
              pkgs.zstd
            ];
          }
          ''
            ipk=$(printf '%s\n' ${ziti-edge-tunnel-openwrt}/*.ipk)
            bash ${verify-ipk} "$ipk" mipsel_24kc 1.15.1 6
            bash ${validator-test} "$ipk" ${verify-ipk} 6
            touch $out
          '';
      checks.ziti-edge-tunnel-openwrt-service =
        pkgs.runCommand "ziti-edge-tunnel-openwrt-service-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.busybox
            ];
          }
          ''
            BUSYBOX=${pkgs.busybox}/bin/busybox \
            bash ${../../nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh} \
              ${../../nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel} \
              ${../../nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/run-managed} \
              bash "${pkgs.busybox}/bin/busybox ash"
            touch $out
          '';
      checks.ziti-openwrt-tunnel-script =
        pkgs.runCommand "ziti-openwrt-tunnel-script-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.jq
            ];
          }
          ''
            bash ${../../scripts/tests/ziti-openwrt-tunnel-test.sh} \
              ${../../scripts/ziti-openwrt-tunnel.sh}
            touch $out
          '';
    };
}
