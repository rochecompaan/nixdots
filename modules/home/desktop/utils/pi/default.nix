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
  };
}
