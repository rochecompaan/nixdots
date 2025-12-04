# { config, ... }:
{
  programs = {
    git = {
      enable = true;

      signing = {
        signByDefault = true;
        key = "0EFBE04F978347E4";
      };

      ignores = [
        "*.log"
        ".envrc"
        "shell.nix"
      ];

      settings = {
        user = {
          email = "roche@upfrontsoftware.co.za";
          name = "rochecompaan";
        };
        aliases = {
          st = " status ";
          ci = "\n        commit ";
          br = "\n        branch ";
          co = "\n        checkout ";
          df = "\n        diff ";
          dc = "\n        diff - -cached ";
          lg = "\n        log - p ";
          pr = "\n        pull - -rebase ";
          p = "\n        push ";
          ppr = "\n        push - -set-upstream origin ";
          lol = "\n        log - -graph - -decorate - -pretty=oneline --abbrev-commit";
          lola = "log --graph --decorate --pretty=oneline --abbrev-commit --all";
          latest = "for-each-ref --sort=-taggerdate --format='%(refname:short)' --count=1";
          undo = "git reset --soft HEAD^";
          brd = "branch -D";
        };

        extraConfig = {
          core = {
            editor = "nvim";
            excludesfile = "~/.config/git/ignore";
          };

          credential = {
            helper = "store";
          };

          pull = {
            rebase = true;
          };

          color = {
            ui = true;
            pager = true;
            diff = "auto";
            branch = true;
            # branch = {
            #   current = "green bold";
            #   local = "yellow dim";
            #   remove = "blue";
            # };

            showBranch = "auto";
            interactive = "auto";
            grep = "auto";
            status = true;
            # status = {
            #   added = "green";
            #   changed = "yellow";
            #   untracked = "red dim";
            #   branch = "cyan";
            #   header = "dim white";
            #   nobranch = "white";
            # };
          };
        };

      };
    };

    # zsh.initExtra = # bash
    #   ''
    #     export GITHUB_TOKEN="$(cat ${config.sops.secrets."github/access-token".path})"
    #     export ANTHROPIC_API_KEY="$(cat ${config.sops.secrets."ANTHROPIC_API_KEY".path})"
    #   '';
  };

  # sops.secrets = {
  #   "github/access-token" = {
  #     path = "${config.home.homeDirectory}/.config/gh/access-token";
  #   };
  #   "GITPRIVATETOKEN" = {
  #     path = "${config.home.homeDirectory}/.gitcreds";
  #   };
  #   "ANTHROPIC_API_KEY" = {
  #     path = "${config.home.homeDirectory}/.config/ANTHROPIC_API_KEY";
  #   };
  # };
}
