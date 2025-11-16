{ config, lib, ... }:
{
  options = {
    default = {
      de = lib.mkOption {
        type = lib.types.enum [
          ""
          "hyprland"
          "niri"
        ];
        # Hosts must opt-in to a desktop environment
        default = "";
      };
      isDesktop = lib.mkOption {
        type = lib.types.bool;
        # Any non-empty DE implies a desktop session
        default = config.default.de != "";
      };
      browser = lib.mkOption {
        type = lib.types.enum [
          "firefox"
          "qutebrowser"
        ];
        default = "firefox";
      };
      terminal = lib.mkOption {
        type = lib.types.enum [
          "wezterm"
          "foot"
          "kitty"
        ];
        default = "kitty";
      };
    };
  };
}
