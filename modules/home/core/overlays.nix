{ inputs, ... }:
{
  nixpkgs.overlays = [
    inputs.nur.overlays.default
    (_: prev: {
      devenv =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
          };
        in
        unstable.devenv;
    })
    (_: prev: {
      zellij =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
          };
        in
        unstable.zellij;
    })
    (_: prev: { zjstatus = inputs.zjstatus.packages.${prev.system}.default; })
    (_: prev: {
      zoom-us =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
            config = {
              allowUnfree = true;
            };
          };
        in
        unstable.zoom-us;
    })
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
      aider-chat =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
          };
        in
        unstable.aider-chat;
    })
    (_: prev: {
      k8sgpt =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
          };
        in
        unstable.k8sgpt;
    })
    (_: prev: {
      signal-desktop =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
          };
        in
        unstable.signal-desktop;
    })
  ];
}
