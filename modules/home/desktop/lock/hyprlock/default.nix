{
  config,
  lib,
  ...
}:
{
  programs.hyprlock = with config.lib.stylix.colors; {
    enable = true;

    settings = {
      general = {
        disable_loading_bar = true;
        grace = 3;
        hide_cursor = true;
        no_fade_in = false;
      };

      background = lib.mkForce [
        {
          path = "${config.wallpaper}";
          blur_passes = 3;
          blur_size = 8;
        }
      ];

      input-field = lib.mkForce [
        {
          size = "200, 50";
          position = "0, -470";
          monitor = "";
          dots_center = true;
          fade_on_empty = false;
          inner_color = "rgba(0, 0, 0, 1)";
          font_color = "rgba(200, 200, 200, 1)";
          outline_thickness = 5;
          placeholder_text = "Password...";
          shadow_passes = 2;
        }
      ];

      # Time
      label = [
        {
          text = "cmd[update:1000] date +\"%H\"";
          color = "#${base05}";
          font_size = 150;
          font_family = "AlfaSlabOne";
          position = "0, -250";
          halign = "center";
          valign = "top";
        }
        {
          text = "cmd[update:1000] date +\"%M\"";
          color = "#${base05}";
          font_size = 150;
          font_family = "AlfaSlabOne";
          position = "0, -420";
          halign = "center";
          valign = "top";
        }
        # Date
        {
          text = "cmd[update:1000] date +\"%d %b %A\"";
          color = "rgba(255, 255, 255, 1)";
          font_size = 14;
          font_family = "JetBrainsMono NFM ExtraBold";
          position = "0, -130";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };
}
