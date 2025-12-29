#              ╭──────────────────────────────────────────────────╮
#              │             CREDITS TO: @khaneliman              │
#              │ THIS IS A FORK OF HIS CONFIG, ALL CREDITS TO HIM │
#              ╰──────────────────────────────────────────────────╯
{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib) mkMerge;

  style = builtins.readFile ./styles/style.css;
  controlCenterStyle = builtins.readFile ./styles/control-center.css;
  powerStyle = builtins.readFile ./styles/power.css;
  statsStyle = builtins.readFile ./styles/stats.css;
  # Use a Niri-specific workspace stylesheet (inlined) to hide the trailing
  # dynamic empty workspace (so only 1..10 show in Waybar). Inlining avoids
  # requiring a committed extra file when building via flakes.
  workspacesStyle =
    if config.default.de == "niri" then
      ''
        #workspaces {
          margin-left: 0;
          padding: 0;
          color: @peach;
          font-weight: bold;
          background-color: @theme_base_color;
          border: none;
        }

        #workspaces button {
          padding: 0 0.25em;
          min-width: 2.5em;
          margin: 0;
          background-color: @theme_base_color;
          color: @text;
          font-weight: normal;
        }

        #workspaces button label {
          padding: 0;
          margin: 0;
        }

        #workspaces button.empty {
          color: @overlay0;
          opacity: 0.7;
        }

        #workspaces button.active {
          color: @green;
          font-weight: bold;
          border-bottom: 2px solid @green;
        }

        #workspaces button.visible {
          color: @blue;
          border-bottom: 2px solid @blue;
        }

        #workspaces button.urgent {
          color: @red;
          font-weight: bold;
          animation: blink 1s infinite;
          border: 1px solid @red;
        }

        /* Niri exposes an extra empty workspace at the end. */
        /* Visually collapse the last empty workspace to keep it at 10. */
        #workspaces button:last-child.empty {
          /* Keep to GTK-supported properties */
          min-width: 0;
          padding: 0;
          margin: 0;
          border: none;
          color: transparent;
          background: transparent;
          font-size: 0;
          opacity: 0; /* visually hide */
          box-shadow: none;
          outline: 0;
        }

        @keyframes blink {
          50% {
            background-color: @red;
            color: @surface0;
          }
        }
      ''
    else
      builtins.readFile ./styles/workspaces.css;

  custom-modules = import ./modules/custom-modules.nix { inherit config lib pkgs; };
  default-modules = import ./modules/default-modules.nix { inherit config lib pkgs; };
  group-modules = import ./modules/group-modules.nix;
  hyprland-modules = import ./modules/hyprland-modules.nix { inherit config lib; };
  niri-modules = import ./modules/niri-modules.nix;

  commonAttributes = {
    layer = "top";
    position = "top";
    margin-top = 0;
    margin-left = 0;
    margin-right = 0;

    modules-left =
      if config.default.de == "hyprland" then
        [
          "hyprland/workspaces"
          "custom/separator-left"
        ]
      else
        [
          "niri/workspaces"
          "custom/separator-left"
        ];
  };

  fullSizeModules = {
    modules-right = [
      "group/tray"
      "custom/separator-right"
      "group/stats"
      "custom/separator-right"
      "group/control-center"
      "battery"
      "clock"
      "custom/power"
    ]
    ++ lib.optionals (config.default.de == "hyprland") [ "hyprland/submap" ];
  };

  mkBarSettings = mkMerge (
    [
      commonAttributes
      fullSizeModules
      custom-modules
      default-modules
      group-modules
    ]
    ++ lib.optionals (config.default.de == "hyprland") [ hyprland-modules ]
    ++ lib.optionals (config.default.de == "niri") [ niri-modules ]
  );

  generateOutputSettings =
    outputList:
    builtins.listToAttrs (
      builtins.map (outputName: {
        name = outputName;
        value = mkMerge [
          mkBarSettings
          { output = outputName; }
        ];
      }) outputList
    );

in
{
  programs.waybar = {
    enable = true;
    # Under niri, prefer compositor autostart over systemd to ensure env is set
    systemd.enable = lib.mkIf (config.default.de == "hyprland") true;

    settings = generateOutputSettings [
      "eDP-1"
      "HDMI-A-1"
      "DP-1"
      "DP-3"
      "DP-4"
      "DP-5"
      "DP-6"
      "DP-7"
    ];
    style =
      with config.lib.stylix.colors;
      mkMerge [
        ''
          @define-color surface0  #${base01};
          @define-color surface1  #${base01};
          @define-color surface2  #${base01};
          @define-color surface3  #${base01};

          @define-color overlay0  #${base02};

          @define-color surface4  #${base00};
          @define-color theme_base_color #${base00};

          @define-color text #${base05};
          @define-color theme_text_color #${base05};

          @define-color red    #${base08};
          @define-color orange #${base09};
          @define-color peach #${base09};
          @define-color yellow #${base0A};
          @define-color green  #${base0B};
          @define-color purple #${base0E};
          @define-color blue   #${base0D};
          @define-color lavender #${base0E};
          @define-color teal #${base0C};
        ''
        "${style}${controlCenterStyle}${powerStyle}${statsStyle}${workspacesStyle}"
      ];
  };
}
