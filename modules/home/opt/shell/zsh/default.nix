{ config, lib, ... }:
{
  imports = [ ./run-as-service.nix ];

  config = lib.mkIf config.modules.zsh.enable {
    programs.zsh = {
      enable = true;
      enableCompletion = true;
      history.size = 1000000;
      history.path = "${config.xdg.dataHome}/zsh/history";
      syntaxHighlighting = {
        enable = true;
      };
      sessionVariables = {
        EDITOR = "nvim";
        TERMINAL = "foot";
        BROWSER = "firefox";
        MANPAGER = "nvim +Man!";
        MANWIDTH = "999";
      };

      shellAliases = {
        g = "lazygit";
        k = "kubectl";
        ksy = "kubectl -n kube-system";
        kgp = "kubectl get pods";
        kgs = "kubectl get services";

        # Colorize grep output (good for log files)
        grep = "grep --color=auto";
        egrep = "egrep --color=auto";
        fgrep = "fgrep --color=auto";

        # confirm before overwriting something
        cp = "cp -i";
        mv = "mv -i";
        rm = "rm -i";

        # easier to read disk
        df = "df -h"; # human-readable sizes
        free = "free -m"; # show sizes in MB

        # get top process eating memory
        psmem = "ps auxf | sort -nr -k 4 | head -5";

        # get top process eating cpu ##
        pscpu = "ps auxf | sort -nr -k 3 | head -5";

        # gpg encryption
        # verify signature for isos
        gpg-check = "gpg2 --keyserver-options auto-key-retrieve --verify";
        # receive the key of a developer
        gpg-retrieve = "gpg2 --keyserver-options auto-key-retrieve --receive-keys";

        cat = "bat -pp --theme \"Visual Studio Dark+\"";
        catt = "bat --theme \"Visual Studio Dark+\"";
        ls = "exa";
        ll = "ls -alF";
        la = "ls -A";
        l = "ls -CF";
        terraform = "tofu";
        tfplan = "tofu plan -out=\"tfplan.out\" && tofu show -no-color tfplan.out >> .terraform/tfplan-$(date +%Y%m%d-%H%M%S).log";
        tfapply = "tofu apply \"tfplan.out\"";
        iplocal = "ip -json route get 8.8.8.8 | jq -r '.[].prefsrc'";

        ssh = "TERM=xterm-256color ssh";

        # show history from first entry
        history = "history 1";

        vpnon = "openvpn3 session-start --config ~/.config/openvpn/sfu.ovpn";
        vpnoff = "openvpn3 session-manage --disconnect --config ~/.config/openvpn/sfu.ovpn";
        vpnstats = "openvpn3 sessions-list";

        myip = "curl -s checkip.amazonaws.com";

        nb = "sudo nixos-rebuild switch --flake .#djangf8sum";
      };

      zplug = {
        enable = true;
        plugins = [
          { name = "zsh-users/zsh-autosuggestions"; }
          { name = "hlissner/zsh-autopair"; }
          { name = "zap-zsh/vim"; }
          { name = "zap-zsh/zap-prompt"; }
          { name = "zap-zsh/fzf"; }
          { name = "zap-zsh/exa"; }
          { name = "zsh-users/zsh-syntax-highlighting"; }
          { name = "svenXY/timewarrior"; }
        ];
      };

      initExtra = ''
        PROMPT_EOL_MARK=\'\'
        source <(kubectl completion zsh)
        eval "$(zoxide init zsh)"

        setopt completeinword NO_flowcontrol NO_listbeep NO_singlelinezle
        autoload -Uz compinit
        compinit

        # keybinds
        bindkey '^ ' autosuggest-accept
        bindkey -v
        bindkey '^R' history-incremental-search-backward

        #compdef toggl
        _toggl() {
          eval \$(env COMMANDLINE="\''${words[1,\$CURRENT]}" _TOGGL_COMPLETE=complete-zsh  toggl)
        }
        if [[ "\$(basename -- \''${(%):-%x})" != "_toggl" ]]; then
          compdef _toggl toggl
        fi

        export PATH="$HOME/.krew/bin:$PATH"
      '';
    };

    programs.atuin = {
      enable = true;
      enableZshIntegration = true;
      settings = {
        style = "compact";
        show_tabs = false;
        show_help = false;
        enter_accept = true;
        filter_mode = "directory";
      };
    };
    home.file.kubie = {
      target = ".kube/kubie.yaml";
      text = ''
        prompt:
          disable: true
      '';
    };

    programs.starship = with config.lib.stylix.colors; {
      enable = true;
      settings = {
        format = "$username$hostname$directory$git_branch$git_state$git_status$cmd_duration$line_break$\{custom.aws\}$kubernetes$python$nix_shell$line_break$character";

        add_newline = true;
        azure.disabled = true;
        c.disabled = true;
        cmake.disabled = true;
        haskell.disabled = true;
        ruby.disabled = true;
        rust.disabled = true;
        perl.disabled = true;
        package.disabled = true;
        lua.disabled = true;
        java.disabled = true;
        golang.disabled = true;

        character = {
          success_symbol = "[>](#${base05} bold)";
          error_symbol = "[x](#${base08} bold)";
          vicmd_symbol = "[<](#${base03})";
        };
        directory = {
          style = "bold yellow";
          format = "[ $path ]($style)";
          truncation_length = 0;
        };
        git_branch = {
          format = "[$branch]($style)";
          style = "bold purple";
        };
        git_state = {
          format = "\([$state( $progress_current/$progress_total)]($style)\) ";
          style = "bright-black";
        };
        git_status = {
          format = "[[(*$conflicted$untracked$modified$staged$renamed$deleted)](218) ($ahead_behind$stashed)]($style)";
          style = "cyan";
          conflicted = "​";
          untracked = "​";
          modified = "​";
          staged = "​";
          renamed = "​";
          deleted = "​";
          stashed = "≡";
        };
        cmd_duration = {
          min_time = 1;
          # duration & style ;
          format = "[]($style)[[  ](bg:#${base01} fg:#${base08} bold)$duration](bg:#${base01}
fg:#${base05} bold)[]($style)";
          disabled = false;
          style = "bg:none fg:#${base01}";
        };
        nix_shell = {
          disabled = false;
          heuristic = false;
          format = "[]($style)[nix](bg:#${base01} fg:#${base05} bold)[]($style)";
          style = "bg:none fg:#${base01}";
          impure_msg = "";
          pure_msg = "";
          unknown_msg = "";
        };
        kubernetes = {
          format = "[](fg:#${base01} bg:none)[ k8s:](fg:#${base0D}
bg:#${base01})[$context/$namespace]($style)[](fg:#${base01} bg:none) ";
          disabled = false;
          style = "fg:#${base05} bg:#${base01} bold";
          context_aliases = {
            "dev.local.cluster.k8s" = "dev";
          };
          user_aliases = {
            "dev.local.cluster.k8s" = "dev";
            "root/.*" = "root";
          };
        };
        gcloud = {
          format = "[](fg:#${base01} bg:none)[ gcp:](fg:#${base08}
bg:#${base01})[$project]($style)[](fg:#${base01} bg:none) ";
          style = "fg:#${base05} bg:#${base01} bold";
          disabled = true;
        };
        custom = {
          aws = {
            style = "fg:#${base05} bg:#${base01} bold";
            command = "echo \$AWS_PROFILE";
            detect_files = [ ];
            when = " test \"\$AWS_PROFILE\" != \"\" ";
            format = "on [aws:($output )]($style)";
            symbol = "";
            disabled = false;
          };
        };
      };
    };
  };
}
