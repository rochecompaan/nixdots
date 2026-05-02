{ config, pkgs, ... }:
let
  piFiles = import ./files.nix {
    inherit config pkgs;
  };
in
{
  home.packages = [ piFiles.notionCli ];

  home.file = {
    ".pi/agent/settings.json" = {
      force = true;
      text = builtins.toJSON piFiles.piSettings;
    };

    ".pi/agent/extensions".source = "${piFiles.package}/.pi/agent/extensions";
    ".pi/agent/agent-teams".source = ./agent-teams;
    ".pi/agent/agents".source = ./agents;
    ".pi/agent/skills".source = "${piFiles.package}/.pi/agent/skills";
    ".pi/agent/themes/stylix.json".text = builtins.toJSON piFiles.stylixPiTheme;

    # Node modules for extensions
    ".pi/agent/node_modules/diff".source = "${piFiles.diffPackage}/lib/node_modules/diff";
  };
}
