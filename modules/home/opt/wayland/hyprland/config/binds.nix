{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) getExe;
  # Binds $mod + [shift +] {1..10} to [move to] workspace {1..10}
  workspaces = builtins.concatLists (
    builtins.genList (
      x:
      let
        ws =
          let
            c = (x + 1) / 10;
          in
          builtins.toString (x + 1 - (c * 10));
      in
      [
        "SUPER, ${ws}, workspace, ${toString (x + 1)}"
        "SUPER SHIFT, ${ws}, movetoworkspace, ${toString (x + 1)}"
      ]
    ) 10
  );
  zellij-attach = pkgs.writeShellScriptBin "zellij-attach" ''
    #! /bin/sh

    session=$(zellij ls -sn | rofi -dmenu -theme ~/.config/rofi/config.rasi -p "zellij session:" )

    if [[ -z $session ]]; then
      exit
    fi

    ${terminal} -e zellij attach --create $session
  '';

  hypr-screenshot = pkgs.writeShellScriptBin "hypr-screenshot" ''
    #! /bin/sh
    ${pkgs.grimblast}/bin/grimblast save area - | ${pkgs.swappy}/bin/swappy -f -
  '';

  # Get default application
  terminal = config.home.sessionVariables.TERMINAL;
in
{
  wayland.windowManager.hyprland = {
    settings = {
      bind =
        let
          monocle = "dwindle:no_gaps_when_only";
        in
        [
          # Compositor commands
          "SUPER SHIFT, Q, exit"
          "SUPER, Q, killactive"
          "SUPER, S, togglesplit"
          "SUPER, F, fullscreen"
          "SUPER SHIFT, P, pin"
          "SUPER, Space, togglefloating"

          # Toggle "monocle" (no_gaps_when_only)
          "SUPER, M, exec, hyprctl keyword ${monocle} $(($(hyprctl getoption ${monocle} -j | jaq -r '.int') ^ 1))"

          # Grouped (tabbed) windows
          "SUPER, G, togglegroup"
          "SUPER, TAB, changegroupactive, f"
          "SUPER SHIFT, TAB, changegroupactive, b"

          # Cycle through windows
          "ALT, Tab, cyclenext"
          "ALT, Tab, bringactivetotop"
          "ALT SHIFT, Tab, cyclenext, prev"
          "ALT SHIFT, Tab, bringactivetotop"

          # Move focus
          "SUPER, h, movefocus, l"
          "SUPER, l, movefocus, r"
          "SUPER, j, movefocus, u"
          "SUPER, k, movefocus, d"

          # Move windows
          "SUPER SHIFT, h, movewindow, l"
          "SUPER SHIFT, l, movewindow, r"
          "SUPER SHIFT, j, movewindow, u"
          "SUPER SHIFT, k, movewindow, d"

          # Special workspaces
          "SUPER SHIFT, grave, movetoworkspace, special"
          "SUPER, grave, togglespecialworkspace"

          # Cycle through workspaces
          "SUPER ALT, up, workspace, m-1"
          "SUPER ALT, down, workspace, m+1"

          # Utilities
          "SUPER, Return, exec, run-as-service kitty"
          "SUPER SHIFT, Z, exec, ${getExe zellij-attach}"
          "SUPER SHIFT, B, exec, firefox"
          "SUPER SHIFT, L, exec, hyprlock"
          "SUPER ALT, 0, exec, qalculate-gtk"
          "SUPER, P, exec, 1password"
          "SUPER, O, exec, run-as-service wl-ocr"

          # Screenshot
          "SUPER SHIFT, S, exec, ${getExe hypr-screenshot}"
          "SUPER SHIFT, T, exec, kitty -e twt"
        ]
        ++ workspaces;

      bindr = [
        # Launchers
        " SUPER, R, exec, rofi -show drun"
        " SUPER SHIFT, p, exec, rofi-rbw --no-help --clipboarder wl-copy --keybindings Alt+x:type:password "
        " SUPER SHIFT, e, exec, bemoji -t "
        " SUPER SHIFT, o, exec, wezterm start --class clipse clipse "
      ];

      binde = [
        # Audio
        ",XF86AudioRaiseVolume, exec, volumectl up 5 "
        ",XF86AudioLowerVolume, exec, volumectl down 5 "
        ",XF86AudioMute, exec, volumectl toggle-mute "
        ",XF86AudioMicMute, exec, ${pkgs.pamixer}/bin/pamixer --default-source --toggle-mute "

        # Brightness
        ",XF86MonBrightnessUp, exec, lightctl up 5 "
        ",XF86MonBrightnessDown, exec, lightctl down 5 "
      ];

      # Mouse bindings
      bindm = [
        " SUPER, mouse:272, movewindow "
        " SUPER, mouse:273, resizewindow "
      ];
    };

    # Configure submaps
    extraConfig = ''
      submap = resize
      binde = , right, resizeactive, 10 0
      binde = , left, resizeactive, -10 0
      binde = , up, resizeactive, 0 -10
      binde = , down, resizeactive, 0 10
      bind = , escape, submap, reset
      submap = reset
    '';
  };
}
