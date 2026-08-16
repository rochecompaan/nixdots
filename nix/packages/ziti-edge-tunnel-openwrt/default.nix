{ pkgs }:
let
  inherit (pkgs) lib;

  version = "1.15.1";
  openwrtVersion = "24.10.3";
  target = "ramips/mt7621";
  architecture = "mipsel_24kc";

  sdk = import ./sdk.nix {
    inherit pkgs openwrtVersion target;
  };
  inherit (sdk) nativeTools preparedSdk;

  openwrtBaseFeed = pkgs.fetchFromGitHub {
    owner = "openwrt";
    repo = "openwrt";
    rev = "v${openwrtVersion}";
    hash = "sha256-NCaY7quqGea+9/MzytjnKTlTcCv2LanMXIZFcQ4L7SI=";
  };

  openwrtPackagesFeed = pkgs.fetchFromGitHub {
    owner = "openwrt";
    repo = "packages";
    rev = "44cff71992c291ae11b7b37606c70db62dc0674e";
    hash = "sha256-Bx5zb3FC3VdSc2oo3i9fZ/uO+lqXmaEZrBWn+ED9Wtc=";
  };

  zitiTunnelSrc = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "ziti-tunnel-sdk-c";
    rev = "v${version}";
    hash = "sha256-ZSTurUxd5tsnK/cCEynKLjSoaJUCOJQNLZ9RE5Mf3oU=";
  };

  zitiSdkBase = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "ziti-sdk-c";
    tag = "1.15.0";
    hash = "sha256-o1Hcrqz+e2vJZjnPxIAgy5xKwu+M24o/Knh99dwTR3I=";
  };

  lwipSrc = pkgs.fetchFromGitHub {
    owner = "lwip-tcpip";
    repo = "lwip";
    rev = "STABLE-2_2_1_RELEASE";
    hash = "sha256-8TYbUgHNv9SV3l203WVfbwDEHFonDAQqdykiX9OoM34=";
  };

  lwipContribSrc = pkgs.fetchFromGitHub {
    owner = "netfoundry";
    repo = "lwip-contrib";
    rev = "STABLE-2_1_0_RELEASE";
    hash = "sha256-Ypn/QfkiTGoKLCQ7SXozk4D/QIdo4lyza4yq3tAoP/0=";
  };

  subcommandSrc = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "subcommands.c";
    rev = "87350797774530b6ba9c00017f0f53dd57e6c38e";
    hash = "sha256-Gz0/b9jcC1I0fmguSMkV0xiqKWq7vzUVT0Bd1F4iqkA=";
  };

  tlsuvBase = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "tlsuv";
    rev = "v0.41.1";
    hash = "sha256-mT1K8OpwE+brdEc6ik8jMhEsXGuEh5nqfY3urx7IQiA=";
  };

  zitiSdkSrc = pkgs.runCommand "ziti-sdk-c-1.15.0-openwrt-src" { } ''
        cp -R ${zitiSdkBase} $out
        chmod -R u+w $out
        substituteInPlace $out/library/CMakeLists.txt \
          --replace-fail \
            'pkg_check_modules(STC REQUIRED IMPORTED_TARGET stc)' \
            'add_library(stc STATIC
      "${pkgs.stc.src}/src/cstr_core.c"
      "${pkgs.stc.src}/src/cstr_io.c"
      "${pkgs.stc.src}/src/cstr_utf8.c"
      "${pkgs.stc.src}/src/cregex.c"
      "${pkgs.stc.src}/src/csview.c"
      "${pkgs.stc.src}/src/cspan.c"
      "${pkgs.stc.src}/src/fmt.c"
      "${pkgs.stc.src}/src/random.c"
      "${pkgs.stc.src}/src/stc_core.c"
    )
    target_include_directories(stc PUBLIC "${pkgs.stc.src}/include")
    add_library(PkgConfig::STC ALIAS stc)'
  '';

  tlsuvSrc = pkgs.runCommand "tlsuv-0.41.1-openwrt-src" { } ''
    cp -R ${tlsuvBase} $out
    chmod -R u+w $out
    substituteInPlace $out/CMakeLists.txt \
      --replace-fail \
        '    find_package(llhttp CONFIG REQUIRED)' \
        '    add_subdirectory("''${LLHTTP_SOURCE_DIR}" "''${CMAKE_CURRENT_BINARY_DIR}/llhttp" EXCLUDE_FROM_ALL)'
  '';

  packageTree = pkgs.runCommand "ziti-edge-tunnel-openwrt-package-tree" { } ''
    cp -R ${./openwrt} $out
    chmod -R u+w $out
    substituteInPlace $out/Makefile \
      --subst-var-by zitiTunnelSrc ${zitiTunnelSrc} \
      --subst-var-by zitiSdkSrc ${zitiSdkSrc} \
      --subst-var-by lwipSrc ${lwipSrc} \
      --subst-var-by lwipContribSrc ${lwipContribSrc} \
      --subst-var-by llhttpSrc ${pkgs.llhttp.src} \
      --subst-var-by subcommandSrc ${subcommandSrc} \
      --subst-var-by tlsuvSrc ${tlsuvSrc}
  '';

  prepareSdkTree = ''
        mkdir sdk
        cp -a ${preparedSdk}/. sdk/
        chmod -R u+w sdk
        rm -rf sdk/feeds sdk/package/feeds sdk/package/ziti-edge-tunnel
        mkdir -p sdk/feeds
        cp -R ${openwrtBaseFeed} sdk/feeds/base
        cp -R ${openwrtPackagesFeed} sdk/feeds/packages
        chmod -R u+w sdk/feeds
        substituteInPlace sdk/feeds/base/package/libs/openssl/Makefile \
          --replace-fail \
            './Configure $(OPENSSL_TARGET)' \
            '${pkgs.perl}/bin/perl ./Configure $(OPENSSL_TARGET)'
        (cd sdk && ./scripts/feeds update -i base packages)
        (cd sdk && ./scripts/feeds install -p base \
          ca-bundle libjson-c libopenssl libpcap zlib)
        (cd sdk && ./scripts/feeds install -p packages \
          libprotobuf-c libsodium libuv)
        cp -R ${packageTree} sdk/package/ziti-edge-tunnel
        cat >>sdk/.config <<'EOF'
    CONFIG_PACKAGE_ziti-edge-tunnel=m
    EOF
        make -C sdk defconfig
        grep -Fx 'CONFIG_TARGET_ramips=y' sdk/.config
        grep -Fx 'CONFIG_TARGET_ramips_mt7621=y' sdk/.config
        grep -Fx 'CONFIG_TARGET_ARCH_PACKAGES="${architecture}"' sdk/.config
  '';

  downloadCache = pkgs.stdenvNoCC.mkDerivation {
    pname = "ziti-edge-tunnel-openwrt-download-cache";
    inherit version;
    nativeBuildInputs = nativeTools ++ [
      pkgs.cacert
      pkgs.curl
    ];
    buildInputs = [ pkgs.ncurses ];
    dontUnpack = true;
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    GIT_SSL_CAINFO = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-QjQUkZmzyZ5C3ZPkfJbN0jxZcqseIbPheznkpZgN25o=";

    buildPhase = ''
      runHook preBuild
      ${prepareSdkTree}
      make -C sdk package/ziti-edge-tunnel/compile -j1 V=s
      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out
      cp -a sdk/dl/. $out/
    '';
  };

in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ziti-edge-tunnel-openwrt";
  inherit version;
  nativeBuildInputs = nativeTools;
  buildInputs = [ pkgs.ncurses ];
  dontUnpack = true;
  strictDeps = true;

  buildPhase = ''
    runHook preBuild
    ${prepareSdkTree}
    mkdir -p sdk/dl
    cp -a ${downloadCache}/. sdk/dl/
    make -C sdk package/ziti-edge-tunnel/compile -j"$NIX_BUILD_CORES" V=sc
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    mapfile -t packages < <(
      find sdk/bin/packages sdk/bin/targets -type f \
        -name "ziti-edge-tunnel_${version}-*_mipsel_24kc.ipk" -print
    )
    if [ "''${#packages[@]}" -ne 1 ]; then
      printf 'expected exactly one ziti-edge-tunnel ipk, found %s\n' "''${#packages[@]}" >&2
      printf '%s\n' "''${packages[@]}" >&2
      exit 1
    fi
    cp "''${packages[0]}" $out/
    (cd $out && sha256sum *.ipk >SHA256SUMS)
    runHook postInstall
  '';

  meta = {
    description = "OpenZiti edge tunneler package for OpenWRT 24.10.3 ramips/mt7621";
    homepage = "https://openziti.io/";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
