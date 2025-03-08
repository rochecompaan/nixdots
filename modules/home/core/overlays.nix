{ inputs, ... }:
{
  nixpkgs.overlays = [
    inputs.nur.overlays.default
    # (_: prev: {
    #   # Fix slack screen sharing following: https://github.com/flathub/com.slack.Slack/issues/101#issuecomment-1807073763
    #   slack = prev.slack.overrideAttrs (previousAttrs: {
    #     installPhase =
    #       previousAttrs.installPhase
    #       + ''
    #         sed -i'.backup' -e 's/,"WebRTCPipeWireCapturer"/,"LebRTCPipeWireCapturer"/' $out/lib/slack/resources/app.asar
    #       '';
    #   });
    # })
    # Zellij 0.41.2 overlay
    (_: prev: {
      zellij = prev.zellij.overrideAttrs (_: rec {
        version = "0.41.2";
        name = "zellij";

        src = prev.fetchFromGitHub {
          owner = "zellij-org";
          repo = "zellij";
          rev = "v0.41.2";
          hash = "sha256-Eufw+AweOd7tVjjEZi/AcIVc7gJQp+sdds777vjC83Y=";
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
  ];
}
