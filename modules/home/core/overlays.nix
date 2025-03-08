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
    (final: prev: {
      zellij = prev.zellij.overrideAttrs (oldAttrs: {
        version = "0.41.2";
        
        src = prev.fetchFromGitHub {
          owner = "zellij-org";
          repo = "zellij";
          rev = "v0.41.2";
          hash = "sha256-Hl4+Vc+ZiA2fkxDQDnJqVEMlQOLfUhQZMSXBPuaX/+Y=";
        };
      });
    })
    (_: prev: { zjstatus = inputs.zjstatus.packages.${prev.system}.default; })
  ];
}
