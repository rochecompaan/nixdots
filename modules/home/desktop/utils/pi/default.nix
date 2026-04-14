{ config, pkgs, ... }:
let
  piFiles = import ./files.nix {
    inherit config pkgs;
  };
in
{
  home.file = {
    ".pi/agent/settings.json".text = builtins.toJSON piFiles.piSettings;

    ".pi/agent/extensions/filter-output.ts".source = ./extensions/filter-output.ts;
    ".pi/agent/extensions/security.ts".source = ./extensions/security.ts;
    ".pi/agent/extensions/theme-cycler.ts".source = ./extensions/theme-cycler.ts;
    ".pi/agent/extensions/review.ts".source = ./extensions/review.ts;

    # New extensions
    ".pi/agent/extensions/answer.ts".source = ./extensions/answer.ts;
    ".pi/agent/extensions/btw.ts".source = ./extensions/btw.ts;
    ".pi/agent/extensions/context.ts".source = ./extensions/context.ts;
    ".pi/agent/extensions/control.ts".source = ./extensions/control.ts;
    ".pi/agent/extensions/files.ts".source = ./extensions/files.ts;
    ".pi/agent/extensions/loop.ts".source = ./extensions/loop.ts;
    ".pi/agent/extensions/multi-edit.ts".source = ./extensions/multi-edit.ts;
    ".pi/agent/extensions/notify.ts".source = ./extensions/notify.ts;
    ".pi/agent/extensions/prompt-editor.ts".source = ./extensions/prompt-editor.ts;
    ".pi/agent/extensions/session-breakdown.ts".source = ./extensions/session-breakdown.ts;
    ".pi/agent/extensions/todos.ts".source = ./extensions/todos.ts;
    ".pi/agent/extensions/uv.ts".source = ./extensions/uv.ts;
    ".pi/agent/extensions/whimsical.ts".source = ./extensions/whimsical.ts;

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
