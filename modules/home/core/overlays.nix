{ inputs, ... }:
{
  nixpkgs.overlays = [
    # Compatibility for flake inputs that have not yet migrated from pkgs.system.
    (_: prev: { system = prev.stdenv.hostPlatform.system; })
    inputs.nur.overlays.default
    (_: prev: {
      devenv =
        let
          unstable = import inputs.nixpkgs-unstable {
            system = prev.stdenv.hostPlatform.system;
          };
        in
        unstable.devenv;
    })
    (_: prev: {
      zellij =
        let
          unstable = import inputs.nixpkgs-unstable {
            system = prev.stdenv.hostPlatform.system;
          };
        in
        unstable.zellij;
    })
    (_: prev: { zjstatus = inputs.zjstatus.packages.${prev.stdenv.hostPlatform.system}.default; })
    (_: prev: {
      zoom-us =
        let
          unstable = import inputs.nixpkgs-unstable {
            system = prev.stdenv.hostPlatform.system;
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
            system = prev.stdenv.hostPlatform.system;
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
            system = prev.stdenv.hostPlatform.system;
          };
        in
        unstable.aider-chat;
    })
    (_: prev: {
      k8sgpt =
        let
          unstable = import inputs.nixpkgs-unstable {
            system = prev.stdenv.hostPlatform.system;
          };
        in
        unstable.k8sgpt;
    })
    (_: prev: {
      signal-desktop =
        let
          unstable = import inputs.nixpkgs-unstable {
            system = prev.stdenv.hostPlatform.system;
          };
        in
        unstable.signal-desktop;
    })
  ];
}
