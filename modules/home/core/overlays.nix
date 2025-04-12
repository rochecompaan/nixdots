{ inputs, ... }:
{
  nixpkgs.overlays = [
    inputs.nur.overlays.default
    # Use unstable version of OBS Studio with Qt fix
    (final: prev: {
      obs-studio = (
        inputs.nixpkgs-unstable.legacyPackages.${prev.system}.obs-studio.overrideAttrs (oldAttrs: {
          # Create a proper wrapper script to ensure correct Qt libraries are used
          postFixup =
            (oldAttrs.postFixup or "")
            + ''
              wrapProgram $out/bin/obs \
                --set LD_LIBRARY_PATH "${final.qt6.qtbase.out}/lib:${final.qt6.qtwayland.out}/lib:${final.qt6.qtdeclarative.out}/lib" \
                --unset QT_STYLE_OVERRIDE \
                --unset QT_QPA_PLATFORMTHEME
            '';
        })
      );
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
    (_: prev: {
      goose-cli =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
            # dependens on unfree tokenizer package
            config = {
              allowUnfree = true;
            };
          };
        in
        unstable.goose-cli;
    })
  ];
}
