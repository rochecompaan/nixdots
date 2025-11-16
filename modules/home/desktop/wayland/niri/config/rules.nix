{ lib, ... }:
{
  # Output and window rules using default Niri syntax
  xdg.configFile."niri/config.kdl".text = lib.mkAfter ''
    // Configure outputs by name (example). Use `niri msg outputs` to list names/modes.
    // output "eDP-1" {
    //   // off
    //   mode "1920x1080@60"
    //   scale 1
    //   transform "normal"
    //   position x=0 y=0
    // }
    // output "HDMI-A-1" {
    //   mode "1920x1080@60"
    //   scale 1
    //   position x=1920 y=0
    // }

    // Window rules: float common utilities
    window-rule { match app-id=r#"^pavucontrol$"#; open-floating true; }
    window-rule { match app-id=r#"^qalculate-gtk$"#; open-floating true; }
    window-rule { match app-id=r#"^imv$"#; open-floating true; }
    window-rule { match app-id=r#"^io\.bassi\.Amberol$"#; open-floating true; }
    window-rule { match app-id=r#"^io\.github\.celluloid_player\.Celluloid$"#; open-floating true; }
    window-rule { match app-id=r#"^nm\-connection\-editor$"#; open-floating true; }
    window-rule { match app-id=r#"^org\.gnome\.Loupe$"#; open-floating true; }
    window-rule { match app-id=r#"^clipse$"#; open-floating true; }
  '';
}
