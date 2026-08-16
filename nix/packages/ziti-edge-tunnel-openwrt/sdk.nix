{
  pkgs,
  openwrtVersion,
  target,
}:
let
  inherit (pkgs) lib;

  openwrtSdkArchive = pkgs.fetchurl {
    url = "https://downloads.openwrt.org/releases/${openwrtVersion}/targets/${target}/openwrt-sdk-${openwrtVersion}-ramips-mt7621_gcc-13.3.0_musl.Linux-x86_64.tar.zst";
    hash = "sha256-xYAMzkFLdEsgJg0Te31EaFAaHanUU94oJxCjs7IIXxo=";
  };

  hostLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.ncurses
    pkgs.libxcrypt
    pkgs.util-linux.lib
    pkgs.xz
    pkgs.zstd
  ];

  nativeTools = [
    pkgs.bash
    pkgs.binutils
    pkgs.coreutils
    pkgs.diffutils
    pkgs.file
    pkgs.findutils
    pkgs.gawk
    pkgs.git
    pkgs.gnugrep
    pkgs.gnumake
    pkgs.gnused
    pkgs.gnutar
    pkgs.patch
    pkgs.patchelf
    pkgs.perl
    pkgs.pkg-config
    pkgs.python3
    pkgs.rsync
    pkgs.stdenv.cc
    pkgs.unzip
    pkgs.util-linux
    pkgs.wget
    pkgs.which
    pkgs.xz
    pkgs.zstd
  ];

  preparedSdk = pkgs.stdenvNoCC.mkDerivation {
    pname = "openwrt-sdk-prepared";
    version = openwrtVersion;
    src = openwrtSdkArchive;
    nativeBuildInputs = nativeTools;
    dontFixup = true;
    dontStrip = true;

    unpackPhase = ''
      runHook preUnpack
      mkdir source
      tar --zstd -xf $src -C source --strip-components=1
      cd source
      runHook postUnpack
    '';

    buildPhase = ''
      runHook preBuild
      grep -F \
        'VERSION_NUMBER:=$(if $(VERSION_NUMBER),$(VERSION_NUMBER),${openwrtVersion})' \
        include/version.mk
      chmod -R u+w .
      patchShebangs .
      substituteInPlace rules.mk \
        --replace-fail /usr/bin/env ${pkgs.coreutils}/bin/env
      while IFS= read -r -d "" candidate; do
        description=$(file -b "$candidate" || true)
        case "$description" in
          *"ELF 64-bit LSB"*"executable"*"x86-64"*"dynamically linked"*)
            old_rpath=$(patchelf --print-rpath "$candidate" 2>/dev/null || true)
            patchelf --set-interpreter "${pkgs.stdenv.cc.bintools.dynamicLinker}" "$candidate"
            patchelf --set-rpath "${hostLibraryPath}''${old_rpath:+:$old_rpath}" "$candidate"
            ;;
        esac
      done < <(find . -type f -perm -0100 -print0)
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a . $out/
      runHook postInstall
    '';
  };
in
{
  inherit nativeTools preparedSdk;
}
