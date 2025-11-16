{ lib, ... }:
{
  # Basic layout + input using Niri default syntax
  xdg.configFile."niri/config.kdl".text = lib.mkAfter ''
    layout {
      gaps 12
    }

    // Input configuration (see default-config.kdl for full options)
    input {
      keyboard {
        xkb {
          layout "us"
          variant "intl"
          options "compose:rctrl,caps:escape"
        }
        // Enable numlock on startup
        numlock
      }

      touchpad {
        // Enable tap-to-click and natural scrolling
        tap
        natural-scroll
        // Libinput options examples
        accel-profile "flat"
        // Enable disable-while-typing heuristics
        dwt
      }
    }

    // Ask clients to omit client-side decorations when possible
    prefer-no-csd
  '';
}
