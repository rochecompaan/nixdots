{ config, lib, ... }:
{
  config = lib.mkIf config.modules.fish.enable {
    programs.fish = {
      enable = true;
      shellAliases = {
        g = "lazygit";
        k = "kubectl";
        ksy = "kubectl -n kube-system";
        kgp = "kubectl get pods";
        kgs = "kubectl get services";
        kgd = "kubectl get deploy,daemonsets";
        kge = "kubectl exec -it";

        # Atuin
        asr = "atuin script run";

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
      };

    };

  };
}
