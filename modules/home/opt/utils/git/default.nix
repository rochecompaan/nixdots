# { config, ... }:
{
  programs = {
    git = {
      enable = true;
      userEmail = "roche@upfrontsoftware.co.za";
      userName = "rochecompaan";

      signing = {
        signByDefault = true;
        key = "F77523F04663C2C7";
      };

      ignores = [
        "*.log"
        ".envrc"
        "shell.nix"
      ];

      extraConfig = {
        core = {
          editor = "nvim";
          excludesfile = "~/.config/git/ignore";
          pager = "delta";
        };
        pager = {
          diff = "delta";
          log = "delta";
          reflog = "delta";
          show = "delta";
        };

        credential = {
          helper = "store";
        };

        color = {
          ui = true;
          pager = true;
          diff = "auto";
          branch = {
            current = "green bold";
            local = "yellow dim";
            remove = "blue";
          };

          showBranch = "auto";
          interactive = "auto";
          grep = "auto";
          status = {
            added = "green";
            changed = "yellow";
            untracked = "red dim";
            branch = "cyan";
            header = "dim white";
            nobranch = "white";
          };
        };

      };

      aliases = {
        st = " status ";
        ci = "
        commit ";
        br = "
        branch ";
        co = "
        checkout ";
        df = "
        diff ";
        dc = "
        diff - -cached ";
        lg = "
        log - p ";
        pr = "
        pull - -rebase ";
        p = "
        push ";
        ppr = "
        push - -set-upstream origin ";
        lol = "
        log - -graph - -decorate - -pretty=oneline --abbrev-commit";
        lola = "log --graph --decorate --pretty=oneline --abbrev-commit --all";
        latest = "for-each-ref --sort=-taggerdate --format='%(refname:short)' --count=1";
        undo = "git reset --soft HEAD^";
        brd = "branch -D";
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
