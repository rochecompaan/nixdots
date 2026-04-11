{ config, pkgs, ... }:
let
  piFiles = import ./files.nix {
    inherit config pkgs;
  };
in
{
  home.file = {
    ".pi/agent/settings.json".text = builtins.toJSON piFiles.piSettings;

    ".pi/agent/extensions/bash-env.ts".source = ./bash-env.ts;
    ".pi/agent/extensions/filter-output.ts".source = ./filter-output.ts;
    ".pi/agent/extensions/security.ts".source = ./security.ts;
    ".pi/agent/extensions/theme-cycler.ts".source = ./theme-cycler.ts;
    ".pi/agent/extensions/review.ts".source = ./review.ts;

    ".pi/agent/skills/linear/SKILL.md".source = ./skills/linear/SKILL.md;

    ".pi/agent/themes/stylix.json".text = builtins.toJSON piFiles.stylixPiTheme;
    ".pi/agent/themes/catppuccin-mocha.json".source = ./themes/catppuccin-mocha.json;
    ".pi/agent/themes/cyberpunk.json".source = ./themes/cyberpunk.json;
    ".pi/agent/themes/dracula.json".source = ./themes/dracula.json;
    ".pi/agent/themes/everforest.json".source = ./themes/everforest.json;
    ".pi/agent/themes/gruvbox.json".source = ./themes/gruvbox.json;
    ".pi/agent/themes/midnight-ocean.json".source = ./themes/midnight-ocean.json;
    ".pi/agent/themes/nord.json".source = ./themes/nord.json;
    ".pi/agent/themes/ocean-breeze.json".source = ./themes/ocean-breeze.json;
    ".pi/agent/themes/rose-pine.json".source = ./themes/rose-pine.json;
    ".pi/agent/themes/synthwave.json".source = ./themes/synthwave.json;
    ".pi/agent/themes/tokyo-night.json".source = ./themes/tokyo-night.json;
  };
}
