{ config, pkgs, ... }:
let
  piFiles = import ./files.nix {
    inherit config pkgs;
  };
in
{
  home.packages = [ piFiles.notionCli ];

  home.file = {
    ".pi/agent/AGENTS.md" = {
      force = true;
      source = "${piFiles.package}/.pi/agent/AGENTS.md";
    };

    ".pi/agent/settings.json" = {
      force = true;
      text = builtins.toJSON piFiles.piSettings;
    };

    ".pi/agent/extensions".source = "${piFiles.package}/.pi/agent/extensions";
    ".pi/agent/agent-teams".source = ./agent-teams;
    ".pi/agent/agents".source = ./agents;
    ".pi/agent/skills".source = "${piFiles.package}/.pi/agent/skills";
    ".pi/agent/themes/stylix.json".text = builtins.toJSON piFiles.stylixPiTheme;

    ".pi/dashboard/config.json" = {
      force = true;
      text = builtins.toJSON {
        port = 18765;
        piPort = 18766;
        tunnel.enabled = false;
      };
    };

    # Node modules for extensions
    ".pi/agent/node_modules/diff".source = "${piFiles.diffPackage}/lib/node_modules/diff";
  };
}
