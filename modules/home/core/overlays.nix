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
    (_: prev: { zjstatus = inputs.zjstatus.packages.${prev.system}.default; })
  ];
}
