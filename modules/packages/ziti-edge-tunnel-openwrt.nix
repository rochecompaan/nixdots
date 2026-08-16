{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      ziti-edge-tunnel-openwrt = import ../../nix/packages/ziti-edge-tunnel-openwrt { inherit pkgs; };
      validator-test = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh;
      verify-ipk = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh;
    in
    {
      packages.ziti-edge-tunnel-openwrt = ziti-edge-tunnel-openwrt;
      checks.ziti-edge-tunnel-openwrt-build = ziti-edge-tunnel-openwrt;
      checks.ziti-edge-tunnel-openwrt-ipk =
        pkgs.runCommand "ziti-edge-tunnel-openwrt-ipk-test"
          {
            nativeBuildInputs = [
              pkgs.binutils
              pkgs.file
              pkgs.gnutar
              pkgs.gzip
              pkgs.python3
              pkgs.xz
              pkgs.zstd
            ];
          }
          ''
            ipk=$(printf '%s\n' ${ziti-edge-tunnel-openwrt}/*.ipk)
            bash ${verify-ipk} "$ipk" mipsel_24kc 1.15.1
            bash ${validator-test} "$ipk" ${verify-ipk}
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
            bash ${../../nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh} \
              ${../../nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel} \
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
