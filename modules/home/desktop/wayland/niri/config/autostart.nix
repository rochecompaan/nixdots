{ ... }:
{
  xdg.configFile."niri/config.kdl".text = ''
    // Autostart common desktop components
    spawn-at-startup "waybar"
    spawn-at-startup "swaync"
  '';
}
