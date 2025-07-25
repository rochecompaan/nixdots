{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib) mkIf mkEnableOption;

  cfg = config.opt.utils.lazygit;
in
{
  options.opt.utils.lazygit.enable = mkEnableOption "lazygit";

  config = mkIf cfg.enable {
    home.packages = with pkgs; [ difftastic ];
    programs.lazygit = {
      enable = true;
      settings = {
        gui = {
          nerdFontsVersion = 3;
          showDivergenceFromBaseBranch = "onlyArrow";
          filterMode = "fuzzy";
          spinner = {
            # The frames of the spinner animation.
            frames = [
              "⠋"
              "⠙"
              "⠩"
              "⠸"
              "⠼"
              "⠴"
              "⠦"
              "⠧"
            ];
            rate = 60;
          };
        };
        git = {
          parseEmoji = true;
          overrideGpg = true;
          paging = {
            # externalDiffCommand = "difft --color=always --syntax-highlight=on";
            colorArg = "always";
            pager = "${lib.getExe pkgs.diff-so-fancy}";
          };
        };
        customCommands = [
          {
            key = "E";
            command = "gitmoji commit";
            description = "commit with gitmoji";
            context = "files";
            loadingText = "opening gitmoji commit tool";
            output = "terminal";
          }
          {
            key = "C";
            command = "git commit";
            description = "commit";
            context = "files";
            loadingText = "opening vim";
            output = "terminal";
          }
        ];
      };
    };
  };
}
