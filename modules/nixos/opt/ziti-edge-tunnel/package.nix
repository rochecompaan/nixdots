{ pkgs, ... }:

pkgs.stdenv.mkDerivation rec {
  pname = "ziti-edge-tunnel";
  version = "1.7.12";

  src = pkgs.fetchgit {
    url = "https://github.com/openziti/ziti-tunnel-sdk-c.git";
    rev = "64900406faec1f02f59b73e3cdfd7e8299c40c76"; # 1.7.12
    hash = "sha256-19KoJfxXLa/oarIG/LZQt0MexcDuiq1HURnridu4kfQ=";
    leaveDotGit = true;
    fetchSubmodules = true;
    deepClone = true;
  };
  ziti_sdk_src = pkgs.fetchgit {
    url = "https://github.com/openziti/ziti-sdk-c.git";
    rev = "ca0d903e5d6826bf1fc78b5a7a6f80222e48a9ff"; # 1.8.5
    hash = "sha256-LbxgAATn15x1n56Ey5cH6WcinadP5kO5s54qpMFQWf0=";
    leaveDotGit = true;
    fetchSubmodules = true;
    deepClone = true;
  };
  lwip_src = pkgs.fetchFromGitHub {
    owner = "lwip-tcpip";
    repo = "lwip";
    rev = "STABLE-2_2_1_RELEASE";
    hash = "sha256-8TYbUgHNv9SV3l203WVfbwDEHFonDAQqdykiX9OoM34=";
  };
  lwip_contrib_src = pkgs.fetchFromGitHub {
    owner = "netfoundry";
    repo = "lwip-contrib";
    rev = "STABLE-2_1_0_RELEASE";
    hash = "sha256-Ypn/QfkiTGoKLCQ7SXozk4D/QIdo4lyza4yq3tAoP/0=";
  };
  subcommand_c_src = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "subcommands.c";
    rev = "main";
    hash = "sha256-Gz0/b9jcC1I0fmguSMkV0xiqKWq7vzUVT0Bd1F4iqkA=";
  };
  tlsuv_src = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "tlsuv";
    rev = "v0.38.1";
    hash = "sha256-JTyLr1OSk2k1+EpK2IfTj9geRW0f7RIua5JkkMpcBUI=";
  };

  postPatch = ''
    # Workaround for broken llhttp package
    mkdir -p patched-cmake
    cp -r ${pkgs.llhttp.dev}/lib/cmake/llhttp patched-cmake/
    substituteInPlace patched-cmake/llhttp/llhttp-config.cmake \
      --replace 'set(_IMPORT_PREFIX "${pkgs.llhttp}")' 'set(_IMPORT_PREFIX "${pkgs.llhttp.dev}")'

    # Patch hardcoded paths to systemd tools
    substituteInPlace programs/ziti-edge-tunnel/netif_driver/linux/resolvers.h \
      --replace '"/usr/bin/busctl"' '"${pkgs.systemd}/bin/busctl"' \
      --replace '"/usr/bin/resolvectl"' '"${pkgs.systemd}/bin/resolvectl"' \
      --replace '"/usr/bin/systemd-resolve"' '"${pkgs.systemd}/bin/systemd-resolve"'
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
    # Ensure a concrete version is embedded; upstream library stringifies ZITI_VERSION
    "-DCMAKE_C_FLAGS=-DZITI_VERSION=v${version}"
    "-DCMAKE_CXX_FLAGS=-DZITI_VERSION=v${version}"
    "-DFETCHCONTENT_SOURCE_DIR_LWIP=../deps/lwip"
    "-DFETCHCONTENT_SOURCE_DIR_LWIP-CONTRIB=../deps/lwip-contrib"
    "-DFETCHCONTENT_SOURCE_DIR_SUBCOMMAND=../deps/subcommand.c"
    "-DFETCHCONTENT_SOURCE_DIR_TLSUV=../deps/tlsuv"
    "-DDOXYGEN_OUTPUT_DIR=/tmp/doxygen"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
  ];

  nativeBuildInputs = with pkgs; [
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

  propagatedBuildInputs = with pkgs; [
    systemd # For the resolvectl command at runtime
  ];

  meta.main = "ziti-edge-tunnel";
}
