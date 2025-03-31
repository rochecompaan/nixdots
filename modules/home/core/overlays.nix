{ inputs, ... }:
{
  nixpkgs.overlays = [
    inputs.nur.overlays.default
    # Use unstable version of OBS Studio
    (_: prev: {
      inherit (inputs.nixpkgs-unstable.legacyPackages.${prev.system}) obs-studio;
    })
    # Zellij 0.41.2 overlay
    (_: prev: {
      zellij = prev.zellij.overrideAttrs (_: rec {
        version = "0.41.2";
        name = "zellij";

        src = prev.fetchFromGitHub {
          owner = "zellij-org";
          repo = "zellij";
          rev = "v0.41.2";
          hash = "sha256-xdWfaXWmqFJuquE7n3moUjGuFqKB90OE6lqPuC3onOg=";
        };

        postPatch = ''
          substituteInPlace Cargo.toml \
            --replace-fail ', "vendored_curl"' ""
        '';
        cargoDeps = prev.rustPlatform.fetchCargoTarball {
          inherit src;
          name = "${name}-${version}";
          hash = "sha256-38hTOsa1a5vpR1i8GK1aq1b8qaJoCE74ewbUOnun+Qs=";
        };
      });
    })
    (_: prev: { zjstatus = inputs.zjstatus.packages.${prev.system}.default; })
    (_: prev: {
      _1password-gui =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
            config = {
              allowUnfree = true;
            };
          };
        in
        unstable._1password-gui;
    })
  ];
}
