{ pkgs }:

let
  rustStdWasm32Wasip1 = pkgs.fetchurl {
    url = "https://static.rust-lang.org/dist/2025-11-10/rust-std-1.91.1-wasm32-wasip1.tar.xz";
    hash = "sha256-cO6Ag3OpIQrEnSCLDNGfgxL0Dtwlb4QBjz1CKZk07SY=";
  };

  rustSysrootWasm32Wasip1 =
    pkgs.runCommand "rust-sysroot-wasm32-wasip1"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.python3
          pkgs.xz
        ];
      }
      ''
        cp -a ${pkgs.rust.packages.prebuilt.rustc-unwrapped}/. $out
        chmod -R u+w $out
        tar -xf ${rustStdWasm32Wasip1}
        patchShebangs rust-std-1.91.1-wasm32-wasip1
        ./rust-std-1.91.1-wasm32-wasip1/install.sh \
          --prefix=$out \
          --components=rust-std-wasm32-wasip1
      '';

  rustPlatform = pkgs.makeRustPlatform {
    inherit (pkgs.rust.packages.prebuilt) cargo rustc;
  };
in
{
  session-shortcuts = rustPlatform.buildRustPackage rec {
    pname = "zellij-session-shortcuts";
    version = "0.1.0";

    src = pkgs.lib.cleanSourceWith {
      src = ./session-shortcuts;
      filter =
        path: type:
        let
          baseName = baseNameOf path;
        in
        !(type == "directory" && baseName == "target");
    };

    cargoHash = "sha256-tf6BqKYbNhRVkRfCnT1VcMqwg10JYTwloKpU47KpzU4=";

    RUSTFLAGS = "--sysroot ${rustSysrootWasm32Wasip1}";
    doCheck = false;

    buildPhase = ''
      runHook preBuild
      cargo build --release --offline --target wasm32-wasip1
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 target/wasm32-wasip1/release/zellij-session-shortcuts.wasm \
        $out/share/zellij/plugins/session-shortcuts.wasm
      runHook postInstall
    '';
  };
}
