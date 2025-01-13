{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib) mkIf mkEnableOption;

  sesh = pkgs.writeScriptBin "sesh" ''
    #! /usr/bin/env sh

    # Taken from https://github.com/zellij-org/zellij/issues/884#issuecomment-1851136980
    # select a directory using zoxide
    ZOXIDE_RESULT=$(zoxide query --interactive)
    # checks whether a directory has been selected
    if [[ -z "$ZOXIDE_RESULT" ]]; then
    	# if there was no directory, select returns without executing
    	exit 0
    fi
    # extracts the directory name from the absolute path
    SESSION_TITLE=$(echo "$ZOXIDE_RESULT" | sed 's#.*/##')

    # get the list of sessions
    SESSION_LIST=$(zellij list-sessions -n | awk '{print $1}')

    # checks if SESSION_TITLE is in the session list
    if echo "$SESSION_LIST" | grep -q "^$SESSION_TITLE$"; then
    	# if so, attach to existing session
    	zellij attach "$SESSION_TITLE"
    else
    	# if not, create a new session
    	echo "Creating new session $SESSION_TITLE and CD $ZOXIDE_RESULT"
    	cd $ZOXIDE_RESULT
    	zellij attach -c "$SESSION_TITLE"
    fi
  '';

  cfg = config.opt.shell.zellij;
in
{
  options.opt.shell.zellij.enable = mkEnableOption "zellij";

  config = mkIf cfg.enable {

    home.packages = [
      pkgs.tmate
      sesh
    ];

    programs.zellij = {
      enable = true;
      enableZshIntegration = false;
    };

    xdg.configFile."zellij/config.kdl".text = ''
      // If you'd like to override the default keybindings completely, be sure to change "keybinds" to "keybinds clear-defaults=true"
      ui {
          pane_frames {
              hide_session_name false
          }
      }
      keybinds clear-defaults=true {
        normal {
          unbind "Ctrl o"
          unbind "Ctrl q"
          unbind "Ctrl h"
          // uncomment this and adjust key if using copy_on_select=false
          // bind "Alt c" { Copy; }
        }
        locked {
          bind "Ctrl l" { SwitchToMode "Normal"; }
        }
        resize {
          bind "Ctrl n" { SwitchToMode "Normal"; }
          bind "h" "Left" { Resize "Increase Left"; }
          bind "j" "Down" { Resize "Increase Down"; }
          bind "k" "Up" { Resize "Increase Up"; }
          bind "l" "Right" { Resize "Increase Right"; }
          bind "H" { Resize "Decrease Left"; }
          bind "J" { Resize "Decrease Down"; }
          bind "K" { Resize "Decrease Up"; }
          bind "L" { Resize "Decrease Right"; }
          bind "=" "+" { Resize "Increase"; }
          bind "-" { Resize "Decrease"; }
        }
        pane {
          bind "Ctrl p" { SwitchToMode "Normal"; }
          bind "h" "Left" { MoveFocus "Left"; SwitchToMode "Normal"; }
          bind "l" "Right" { MoveFocus "Right"; SwitchToMode "Normal"; }
          bind "Ctrl h" { MovePane "Left"; SwitchToMode "Normal"; }
          bind "Ctrl l" { MovePane "Right"; SwitchToMode "Normal"; }
          bind "j" "Down" { MoveFocus "Down"; SwitchToMode "Normal"; }
          bind "k" "Up" { MoveFocus "Up"; SwitchToMode "Normal"; }
          bind "p" { SwitchFocus; SwitchToMode "Normal"; }
          bind "n" { NewPane; SwitchToMode "Normal"; }
          bind "d" { NewPane "Down"; SwitchToMode "Normal"; }
          bind "r" { NewPane "Right"; SwitchToMode "Normal"; }
          bind "x" { CloseFocus; SwitchToMode "Normal"; }
          bind "z" { ToggleFocusFullscreen; SwitchToMode "Normal"; }
          bind "f" { TogglePaneFrames; SwitchToMode "Normal"; }
          bind "w" { ToggleFloatingPanes; SwitchToMode "Normal"; }
          bind "Ctrl p" { ToggleFloatingPanes; SwitchToMode "Normal"; }
          bind "e" { TogglePaneEmbedOrFloating; SwitchToMode "Normal"; }
          // bind "r" { SwitchToMode "RenamePane"; PaneNameInput 0;}
        }
        tab {
          bind "Ctrl t" { SwitchToMode "Normal"; }
          bind "Ctrl h" { MoveTab "Left"; }
          bind "Ctrl l" { MoveTab "Right"; }
          bind "r" { SwitchToMode "RenameTab"; TabNameInput 0; }
          bind "h" "Left" "Up" "k" { GoToPreviousTab; SwitchToMode "Normal"; }
          bind "l" "Right" "Down" "j" { GoToNextTab; SwitchToMode "Normal"; }
          bind "n" { NewTab; SwitchToMode "Normal"; SwitchToMode "Normal"; }
          bind "x" { CloseTab; SwitchToMode "Normal"; SwitchToMode "Normal"; }
          bind "s" { ToggleActiveSyncTab; SwitchToMode "Normal"; }
          bind "b" { BreakPane; SwitchToMode "Normal"; }
          bind "]" { BreakPaneRight; SwitchToMode "Normal"; }
          bind "[" { BreakPaneLeft; SwitchToMode "Normal"; }
          bind "1" { GoToTab 1; SwitchToMode "Normal"; }
          bind "2" { GoToTab 2; SwitchToMode "Normal"; }
          bind "3" { GoToTab 3; SwitchToMode "Normal"; }
          bind "4" { GoToTab 4; SwitchToMode "Normal"; }
          bind "5" { GoToTab 5; SwitchToMode "Normal"; }
          bind "6" { GoToTab 6; SwitchToMode "Normal"; }
          bind "7" { GoToTab 7; SwitchToMode "Normal"; }
          bind "8" { GoToTab 8; SwitchToMode "Normal"; }
          bind "9" { GoToTab 9; SwitchToMode "Normal"; }
          bind "a" { ToggleTab; SwitchToMode "Normal"; }
        }
        scroll {
          bind "Ctrl s" { SwitchToMode "Normal"; }
          bind "e" { EditScrollback; SwitchToMode "Normal"; }
          bind "s" { SwitchToMode "EnterSearch"; SearchInput 0; }
          bind "G" { ScrollToBottom; SwitchToMode "Normal"; }
          bind "j" "Down" { ScrollDown; }
          bind "k" "Up" { ScrollUp; }
          bind "Ctrl f" "PageDown" "Right" "l" { PageScrollDown; }
          bind "Ctrl b" "PageUp" "Left" "h" { PageScrollUp; }
          bind "d" { HalfPageScrollDown; }
          bind "u" { HalfPageScrollUp; }
          // uncomment this and adjust key if using copy_on_select=false
          // bind "Alt c" { Copy; }
        }
        search {
          bind "Ctrl /" { SwitchToMode "Normal"; }
          bind "j" "Down" { ScrollDown; }
          bind "k" "Up" { ScrollUp; }
          bind "Ctrl f" "PageDown" "Right" "l" { PageScrollDown; }
          bind "Ctrl b" "PageUp" "Left" "h" { PageScrollUp; }
          bind "d" { HalfPageScrollDown; }
          bind "u" { HalfPageScrollUp; }
          bind "n" { Search "down"; }
          bind "p" { Search "up"; }
          bind "c" { SearchToggleOption "CaseSensitivity"; }
          bind "w" { SearchToggleOption "Wrap"; }
          bind "o" { SearchToggleOption "WholeWord"; }
        }
        entersearch {
          bind "Ctrl s" "Esc" { SwitchToMode "Scroll"; }
          bind "Enter" { SwitchToMode "Search"; }
        }
        renametab {
          bind "Ctrl c" { SwitchToMode "Normal"; }
          bind "Esc" { UndoRenameTab; SwitchToMode "Tab"; }
        }
        renamepane {
          bind "Ctrl c" { SwitchToMode "Normal"; }
          bind "Esc" { UndoRenamePane; SwitchToMode "Pane"; }
        }
        session {
          bind "Ctrl x" { SwitchToMode "Normal"; }
          bind "Ctrl x" { SwitchToMode "Scroll"; }
          bind "d" { Detach; }
          bind "w" {
              LaunchOrFocusPlugin "zellij:session-manager" {
            floating true
            move_to_focused_tab true
              };
              SwitchToMode "Normal"
          }
        }
        tmux {
          bind "[" { SwitchToMode "Scroll"; }
          bind "Ctrl b" { Write 2; SwitchToMode "Normal"; }
          bind "\"" { NewPane "Down"; SwitchToMode "Normal"; }
          bind "%" { NewPane "Right"; SwitchToMode "Normal"; }
          bind "z" { ToggleFocusFullscreen; SwitchToMode "Normal"; }
          bind "c" { NewTab; SwitchToMode "Normal"; }
          bind "," { SwitchToMode "RenameTab"; }
          bind "p" { GoToPreviousTab; SwitchToMode "Normal"; }
          bind "n" { GoToNextTab; SwitchToMode "Normal"; }
          bind "Left" { MoveFocus "Left"; SwitchToMode "Normal"; }
          bind "Right" { MoveFocus "Right"; SwitchToMode "Normal"; }
          bind "Down" { MoveFocus "Down"; SwitchToMode "Normal"; }
          bind "Up" { MoveFocus "Up"; SwitchToMode "Normal"; }
          bind "h" { MoveFocus "Left"; SwitchToMode "Normal"; }
          bind "l" { MoveFocus "Right"; SwitchToMode "Normal"; }
          bind "j" { MoveFocus "Down"; SwitchToMode "Normal"; }
          bind "k" { MoveFocus "Up"; SwitchToMode "Normal"; }
          bind "o" { FocusNextPane; }
          bind "d" { Detach; }
          bind "Space" { NextSwapLayout; }
          bind "x" { CloseFocus; SwitchToMode "Normal"; }
        }
        shared_except "locked" {
          bind "Ctrl l" { SwitchToMode "Locked"; }
          bind "Alt n" { NewPane; }
          bind "Alt h" "Alt Left" { MoveFocusOrTab "Left"; }
          bind "Alt l" "Alt Right" { MoveFocusOrTab "Right"; }
          bind "Alt j" "Alt Down" { MoveFocus "Down"; }
          bind "Alt k" "Alt Up" { MoveFocus "Up"; }
          bind "Alt =" "Alt +" { Resize "Increase"; }
          bind "Alt -" { Resize "Decrease"; }
          bind "Alt [" { PreviousSwapLayout; }
          bind "Alt ]" { NextSwapLayout; }
          bind "Alt x" {
              LaunchOrFocusPlugin "zellij:session-manager" {
                floating true
                move_to_focused_tab true
              };
              SwitchToMode "Normal"
          }
        }
        shared_except "normal" "locked" {
          bind "Enter" "Esc" { SwitchToMode "Normal"; }
        }
        shared_except "pane" "locked" {
          bind "Ctrl p" { SwitchToMode "Pane"; }
        }
        shared_except "resize" "locked" {
          bind "Ctrl e" { SwitchToMode "Resize"; }
        }
        shared_except "scroll" "locked" {
          bind "Ctrl s" { SwitchToMode "Scroll"; }
        }
        shared_except "session" "locked" {
          bind "Ctrl x" { SwitchToMode "Session"; }
        }
        shared_except "tab" "locked" {
          bind "Ctrl t" { SwitchToMode "Tab"; }
        }
        shared_except "renametab" "locked" {
          bind "Alt r" { SwitchToMode "RenameTab"; }
        }
        shared_except "tmux" "locked" {
          bind "Ctrl h" { SwitchToMode "Tmux"; }
        }
      }

      plugins {
        tab-bar { path "tab-bar"; }
        status-bar { path "status-bar"; }
        // strider { path "strider"; }
        // compact-bar { path "compact-bar"; }
      }

      // Choose what to do when zellij receives SIGTERM, SIGINT, SIGQUIT or SIGHUP
      // eg. when terminal window with an active zellij session is closed
      // Options:
      //   - detach (Default)
      //   - quit
      //
      on_force_close "detach"

      //  Send a request for a simplified ui (without arrow fonts) to plugins
      //  Options:
      //    - true
      //    - false (Default)
      //
      simplified_ui true

      // Choose the path to the default shell that zellij will use for opening new panes
      // Default: $SHELL
      //
      // default_shell "fish"

      // Toggle between having pane frames around the panes
      // Options:
      //   - true (default)
      //   - false
      //
      pane_frames false

      // Toggle between having Zellij lay out panes according to a predefined set of layouts whenever possible
      // Options:
      //   - true (default)
      //   - false
      //
      // auto_layout true

      // Define color themes for Zellij
      // For more examples, see: https://github.com/zellij-org/zellij/tree/main/example/themes
      // Once these themes are defined, one of them should to be selected in the "theme" section of this file
      //
      themes {
          catppuccin-frappe {
              fg 198 208 245
              bg 98 104 128
              black 41 44 60
              red 231 130 132
              green 166 209 137
              yellow 229 200 144
              blue 140 170 238
              magenta 244 184 228
              cyan 153 209 219
              white 198 208 245
              orange 239 159 118
          }
          catppuccin-latte {
              fg 172 176 190
              bg 172 176 190
              black 76 79 105
              red 210 15 57
              green 64 160 43
              yellow 223 142 29
              blue 30 102 245
              magenta 234 118 203
              cyan 4 165 229
              white 220 224 232
              orange 254 100 11
          }
          catppuccin-macchiato {
              fg 202 211 245
              bg 91 96 120
              black 30 32 48
              red 237 135 150
              green 166 218 149
              yellow 238 212 159
              blue 138 173 244
              magenta 245 189 230
              cyan 145 215 227
              white 202 211 245
              orange 245 169 127
          }
          catppuccin-mocha {
              fg 205 214 244
              bg 88 91 112
              black 24 24 37
              red 243 139 168
              green 166 227 161
              yellow 249 226 175
              blue 137 180 250
              magenta 245 194 231
              cyan 137 220 235
              white 205 214 244
              orange 250 179 135
          }
          gruvbox {
              fg 213 196 161
              bg 40 40 40
              black 60 56 54
              red 204 36 29
              green 152 151 26
              yellow 215 153 33
              blue 69 133 136
              magenta 177 98 134
              cyan 104 157 106
              white 251 241 199
              orange 214 93 14
          }
      }

      // Choose the theme that is specified in the themes section.
      // Default: default
      //
      theme "gruvbox"

      // The name of the default layout to load on startup
      // Default: "default"
      //
      // default_layout "compact"

      // Choose the mode that zellij uses when starting up.
      // Default: normal
      //
      // default_mode "locked"

      // Toggle enabling the mouse mode.
      // On certain configurations, or terminals this could
      // potentially interfere with copying text.
      // Options:
      //   - true (default)
      //   - false
      //
      // mouse_mode false

      // Configure the scroll back buffer size
      // This is the number of lines zellij stores for each pane in the scroll back
      // buffer. Excess number of lines are discarded in a FIFO fashion.
      // Valid values: positive integers
      // Default value: 10000
      //
      // scroll_buffer_size 10000

      // Provide a command to execute when copying text. The text will be piped to
      // the stdin of the program to perform the copy. This can be used with
      // terminal emulators which do not support the OSC 52 ANSI control sequence
      // that will be used by default if this option is not set.
      // Examples:
      //
      // copy_command "xclip -selection clipboard" // x11
      copy_command "wl-copy"                    // wayland
      // copy_command "pbcopy"                     // osx

      // Choose the destination for copied text
      // Allows using the primary selection buffer (on x11/wayland) instead of the system clipboard.
      // Does not apply when using copy_command.
      // Options:
      //   - system (default)
      //   - primary
      //
      // copy_clipboard "primary"

      // Enable or disable automatic copy (and clear) of selection when releasing mouse
      // Default: true
      //
      // copy_on_select false

      // Path to the default editor to use to edit pane scrollbuffer
      // Default: $EDITOR or $VISUAL
      //
      // scrollback_editor "/usr/bin/vim"

      // When attaching to an existing session with other users,
      // should the session be mirrored (true)
      // or should each user have their own cursor (false)
      // Default: false
      //
      // mirror_session true

      // The folder in which Zellij will look for layouts
      //
      // layout_dir "/Users/omerhamerman/dotfiles/zellij/layouts"

      // The folder in which Zellij will look for themes
      //
      // theme_dir "/home/roche/.config/zellij/themes"
    '';
  };
}
