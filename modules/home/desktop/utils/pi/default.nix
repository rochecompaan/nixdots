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
    ".pi/agent/extensions/review.ts".source = ./extensions/review.ts;

    # New extensions
    ".pi/agent/extensions/answer".source = ./extensions/answer;
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

    ".pi/agent/skills/linear/SKILL.md".source = ./skills/linear/SKILL.md;
    ".pi/agent/skills/commit/SKILL.md".source = ./skills/commit/SKILL.md;
    ".pi/agent/skills/frontend-design/SKILL.md".source = ./skills/frontend-design/SKILL.md;
    ".pi/agent/skills/github/SKILL.md".source = ./skills/github/SKILL.md;

    ".pi/agent/themes/stylix.json".text = builtins.toJSON piFiles.stylixPiTheme;

    # Node modules for extensions
    ".pi/agent/node_modules/diff".source = "${piFiles.diffPackage}/lib/node_modules/diff";
  };
}
