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
    cargo = pkgs.rust.packages.prebuilt.cargo;
    rustc = pkgs.rust.packages.prebuilt.rustc;
  };
in
{
  favs = pkgs.fetchurl {
    url = "https://github.com/JoseMM2002/zellij-favs/releases/download/v1.0.4/zellij-favs.wasm";
    hash = "sha256-Bc4nsAbPIdbI5xqPC2bnTSqV8Jzf6EDKNTFbRqXq92Y=";
  };

  harpoon = rustPlatform.buildRustPackage rec {
    pname = "zellij-harpoon";
    version = "0-unstable-2026-05-17";

    src = pkgs.fetchFromGitHub {
      owner = "Nacho114";
      repo = "harpoon";
      rev = "7553290e22516c230e598e4fa81d91b1714a0a08";
      hash = "sha256-JmYcbzxIF6qZs2/RKuspHqNpyDibGp9CVQJj47y/BOQ=";
    };

    cargoHash = "sha256-lsv5Wssakni18jif++fPo3Z5WyBtvPsGpWwG3abR7jQ=";

    RUSTFLAGS = "--sysroot ${rustSysrootWasm32Wasip1}";
    doCheck = false;

    buildPhase = ''
      runHook preBuild
      cargo build --release --offline --target wasm32-wasip1
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 target/wasm32-wasip1/release/harpoon.wasm \
        $out/share/zellij/plugins/harpoon.wasm
      runHook postInstall
    '';
  };
}
