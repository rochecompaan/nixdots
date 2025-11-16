{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) getExe getExe';
in
{
  "custom/ellipses" = {
    format = "";
    tooltip = false;
  };

  "custom/lock" = {
    format = "󰍁";
    tooltip = false;
    on-click = "${getExe config.programs.hyprlock.package}";
  };

  "custom/media" = {
    format = "{icon} {}";
    return-type = "json";
    max-length = 40;
    format-icons = {
      spotify = "";
      default = "🎜";
    };
    escape = true;
    exec = "$HOME/.config/waybar/mediaplayer.py 2> /dev/null";
  };

  "custom/notification" = {
    tooltip = true;
    format = "{icon} {}";
    format-icons = {
      notification = "<span foreground='red'><sup></sup></span>";
      none = "";
      dnd-notification = "<span foreground='red'><sup></sup></span>";
      dnd-none = "";
      inhibited-notification = "<span foreground='red'><sup></sup></span>";
      inhibited-none = "";
      dnd-inhibited-notification = "<span foreground='red'><sup></sup></span>";
      dnd-inhibited-none = "";
    };
    return-type = "json";
    exec-if = "which ${getExe' config.services.swaync.package "swaync-client"}";
    exec = "${getExe' config.services.swaync.package "swaync-client"} -swb";
    on-click = "${getExe' pkgs.coreutils "sleep"} 0.1 && ${getExe' config.services.swaync.package "swaync-client"} -t -sw";
    on-click-right = "${getExe' pkgs.coreutils "sleep"} 0.1 && ${getExe' config.services.swaync.package "swaync-client"} -d -sw";
    escape = true;
  };

  "custom/power" = {
    format = "";
    tooltip = false;
    menu = "on-click";
    menu-file =
      pkgs.writeText "powermenu.xml" # xml
        ''
          <?xml version="1.0" encoding="UTF-8"?>
          <interface>
            <object class="GtkMenu" id="menu">
              <child>
          		  <object class="GtkMenuItem" id="top">
          			  <property name="label">Activity</property>
                </object>
          	  </child>
              <child>
                <object class="GtkSeparatorMenuItem" id="delimiter1"/>
              </child>
              <child>
          		  <object class="GtkMenuItem" id="lock">
          			  <property name="label">Lock</property>
                </object>
          	  </child>
              <child>
          		  <object class="GtkMenuItem" id="logout">
          			  <property name="label">Logout</property>
                </object>
          	  </child>
              <child>
          		  <object class="GtkMenuItem" id="suspend">
          			  <property name="label">Suspend</property>
                </object>
          	  </child>
          	  <child>
                <object class="GtkMenuItem" id="hibernate">
          			  <property name="label">Hibernate</property>
                </object>
          	  </child>
              <child>
                <object class="GtkSeparatorMenuItem" id="delimiter2"/>
              </child>
              <child>
                <object class="GtkMenuItem" id="shutdown">
          			  <property name="label">Shutdown</property>
                </object>
              </child>
              <child>
          		  <object class="GtkMenuItem" id="reboot">
          			  <property name="label">Reboot</property>
          		  </object>
              </child>
            </object>
          </interface>
        '';
    menu-actions =
      let
        systemctl = getExe' pkgs.systemd "systemctl";
        hyprlock = getExe config.programs.hyprlock.package;
        poweroff = getExe' pkgs.systemd "poweroff";
        reboot = getExe' pkgs.systemd "reboot";
        terminal = getExe config.programs.foot.package;
        top = getExe config.programs.btop.package;
        hyprctl = getExe' config.wayland.windowManager.hyprland.package "hyprctl";
        swaymsg = getExe' config.wayland.windowManager.sway.package "swaymsg";
      in
      {
        inherit poweroff reboot;

        hibernate = "${systemctl} hibernate";
        lock = ''([[ "$XDG_CURRENT_DESKTOP" == "Hyprland" ]] && ${hyprlock} --immediate)'';
        suspend = "${systemctl} suspend";
        top = "${terminal} ${top}";
        logout = "$(${hyprctl} dispatch exit || ${swaymsg} exit) && ${systemctl} --user exit ";
      };
  };

  "custom/wlogout" = {
    format = "";
    interval = "once";
    tooltip = false;
    on-click = "${getExe' pkgs.coreutils "sleep"} 0.1 && ${getExe pkgs.wlogout} -c 5 -r 5 -p layer-shell";
  };
}
