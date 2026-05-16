{ config, ... }:
let
  monitorPowerOffCommand =
    if config.default.de == "niri" then
      "niri msg action power-off-monitors"
    else
      "hyprctl dispatch dpms off";
  monitorPowerOnCommand =
    if config.default.de == "niri" then
      "niri msg action power-on-monitors"
    else
      "hyprctl dispatch dpms on";
in
{
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = monitorPowerOnCommand;
      };

      listener = [
        {
          timeout = 300;
          on-timeout = "brightnessctl -s set 10";
          on-resume = "brightnessctl -r";
        }
        {
          timeout = 600;
          on-timeout = "hyprlock";
        }
        {
          timeout = 1800;
          on-timeout = monitorPowerOffCommand;
          on-resume = monitorPowerOnCommand;
        }
      ];
    };
  };
}
