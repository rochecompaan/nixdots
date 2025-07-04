{ inputs, ... }:
{
  nixpkgs.overlays = [
    inputs.nur.overlays.default
    # Use unstable version of OBS Studio with Qt fix
    (final: prev: {
      obs-studio =
        inputs.nixpkgs-unstable.legacyPackages.${prev.system}.obs-studio.overrideAttrs
          (oldAttrs: {
            # Create a proper wrapper script to ensure correct Qt libraries are used
            postFixup =
              (oldAttrs.postFixup or "")
              + ''
                wrapProgram $out/bin/obs \
                  --set LD_LIBRARY_PATH "${final.qt6.qtbase.out}/lib:${final.qt6.qtwayland.out}/lib:${final.qt6.qtdeclarative.out}/lib" \
                  --unset QT_STYLE_OVERRIDE \
                  --unset QT_QPA_PLATFORMTHEME
              '';
          });
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
      claude-code =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
            config = {
              allowUnfree = true;
            };
          };
        in
        unstable.claude-code;
    })
    (_: prev: {
      goose-cli =
        let
          unstable = import inputs.nixpkgs-unstable {
            inherit (prev) system;
            config = {
              allowUnfree = true;
            };
          };
        in
        unstable.goose-cli;
    })
  ];
}
