{
  xdg.configFile."niri/config.kdl".text = ''
    // Autostart common desktop components
    spawn-at-startup "nm-applet"
    spawn-at-startup "blueman-applet"
    spawn-at-startup "element-desktop" "--hidden"
    spawn-at-startup "nextcloud" "--background"
    spawn-at-startup "noctalia-shell"
  '';
}
