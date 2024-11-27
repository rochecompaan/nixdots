{ config, lib, ... }:
let
  inherit (lib)
    mkIf
    mkEnableOption
    mkOption
    types
    ;

  cfg = config.opt.services.hypridle;
in
{
  options.opt.services.hypridle = {
    enable = mkEnableOption "hyprdidle";
    enableSuspend = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to enable suspend after timeout";
    };
  };

  config = mkIf cfg.enable {
    services.hypridle = {
      enable = true;
      settings = {
        general = {
          lock_cmd = "pidof hyprlock || hyprlock";
          before_sleep_cmd = "loginctl lock-session";
          after_sleep_cmd = "hyprctl dispatch dpms on";
        };

        listener =
          [
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
              on-timeout = "hyprctl dispatch dpms off";
              on-resume = "hyprctl dispatch dpms on";
            }
          ]
          ++ lib.optionals cfg.enableSuspend [
            {
              timeout = 1800;
              on-timeout = "systemctl suspend";
            }
          ];
      };
    };
  };
}
