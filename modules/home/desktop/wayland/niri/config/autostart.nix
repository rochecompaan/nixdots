{
  xdg.configFile."niri/config.kdl".text = ''
    // Autostart common desktop components
    spawn-at-startup "sh" "-lc" "NIRI_SOCKET=\"$(ls -1t /run/user/$(id -u)/niri.wayland-*.sock 2>/dev/null | head -n1)\" exec waybar"
  '';
}
