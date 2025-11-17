{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) getExe;
  term = config.home.sessionVariables.TERMINAL or "kitty";
  zellijAttach = pkgs.writeShellScriptBin "zellij-attach" ''
    #! /usr/bin/env bash
    session=$(zellij ls -sn | rofi -dmenu -theme ~/.config/rofi/config.rasi -p "zellij session:" )
    [ -z "$session" ] && exit 0
    ${term} -e zellij attach --create "$session"
  '';
  screenshot = pkgs.writeShellScriptBin "niri-screenshot" ''
    #! /usr/bin/env bash
    ${pkgs.grimblast}/bin/grimblast save area - | ${pkgs.swappy}/bin/swappy -f -
  '';
in
{
  # Binds translated to Niri's default command names
  xdg.configFile."niri/config.kdl".text = lib.mkAfter ''
    binds {
      // Quit / kill
      Mod+Shift+Q { quit; }
      Mod+Q { close-window; }
      Mod+O repeat=false { toggle-overview; }

      // Column/window sizing
      Mod+F { maximize-column; }
      Mod+Shift+F { fullscreen-window; }
      Mod+Space { toggle-window-floating; }

      // Focus movement (H J K L)
      Mod+H { focus-column-left; }
      Mod+J { focus-window-down; }
      Mod+K { focus-window-up; }
      Mod+L { focus-column-right; }

      // Move windows/columns
      Mod+Ctrl+H { move-column-left; }
      Mod+Ctrl+J { move-window-down; }
      Mod+Ctrl+K { move-window-up; }
      Mod+Ctrl+L { move-column-right; }

      // Cycle workspaces (up/down)
      Mod+Alt+Up { focus-workspace-up; }
      Mod+Alt+Down { focus-workspace-down; }

      // Workspaces 1..9 and move column to workspace
      ${lib.concatStringsSep "\n" (
        builtins.genList (
          x:
          let
            i = toString (x + 1);
          in
          ''
            Mod+${i} { focus-workspace ${i}; }
            Mod+Shift+${i} { move-column-to-workspace ${i}; }
          ''
        ) 9
      )}

      // (no dedicated reload action in Niri binds; use `niri msg reload-config`)

      // Launchers / utilities
      Mod+Return { spawn "${term}"; }
      Mod+Shift+Z { spawn "${getExe zellijAttach}"; }
      Mod+Shift+B { spawn "firefox"; }
      Mod+Shift+L { spawn "hyprlock"; }
      Mod+Alt+0 { spawn "qalculate-gtk"; }
      Mod+P { spawn "1password"; }
      Mod+Shift+S { spawn "${getExe screenshot}"; }
      Mod+R { spawn "rofi" "-show" "drun"; }
      Mod+Shift+P { spawn "rofi-rbw" "--no-help" "--clipboarder" "wl-copy" "--keybindings" "Alt+x:type:password"; }
      Mod+Shift+E { spawn "bemoji" "-t"; }
      Mod+Shift+O { spawn "wezterm" "start" "--class" "clipse" "clipse"; }

      // Volume / brightness keys
      XF86AudioRaiseVolume { spawn "volumectl" "up" "5"; }
      XF86AudioLowerVolume { spawn "volumectl" "down" "5"; }
      XF86AudioMute { spawn "volumectl" "toggle-mute"; }
      XF86AudioMicMute { spawn "${getExe pkgs.pamixer}" "--default-source" "--toggle-mute"; }
      XF86MonBrightnessUp { spawn "lightctl" "up" "5"; }
      XF86MonBrightnessDown { spawn "lightctl" "down" "5"; }
    }
  '';
}
