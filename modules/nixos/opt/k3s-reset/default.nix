{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.k3s.reset;
in
with lib;
{
  imports = [ ./options.nix ];

  config = mkIf cfg.enable {
    # Ensure k3s service is disabled declaratively, overriding host settings
    services.k3s.enable = lib.mkForce false;

    # Activation snippet to clean up k3s-related data on each switch
    # Runs only when enabled; safe to keep disabled by default
    system.activationScripts.k3s-wipe = {
      text = ''
        set -euo pipefail
        SENTINEL="/var/lib/.k3s-wiped"
        if [ -e "$SENTINEL" ]; then
          echo "[k3s-reset] wipe already performed; skipping"
          exit 0
        fi

        echo "[k3s-reset] unmounting all kubelet mounts if present"
        # Unmount deepest mountpoints first to avoid busy parent mounts
        mount | awk '$3 ~ /^\/var\/lib\/kubelet/ {print $3}' | sort -r | while read -r m; do
          umount "$m" || true
        done

        echo "[k3s-reset] stopping lingering k3s/kubelet processes if any"
        (systemctl stop k3s || true)
        (systemctl stop kubelet || true)

        echo "[k3s-reset] removing k3s, kubelet, longhorn, etcd, cni data"
        rm -rf /etc/rancher/k3s /etc/rancher/node
        rm -rf /var/lib/rancher/k3s /var/lib/kubelet /var/lib/longhorn /var/lib/etcd /var/lib/cni

        touch "$SENTINEL"
        echo "[k3s-reset] wipe complete (sentinel created)"
      '';
      deps = [ ];
    };

    # Provide an explicit command to run the wipe on demand too
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "k3s-wipe" ''
        set -euo pipefail
        echo "This will stop k3s and remove cluster data from this node."
        read -r -p "Proceed (y/N)? " ans
        case "$ans" in
          y|Y|yes|YES)
            systemctl stop k3s || true
            systemctl stop kubelet || true
            mount | awk '$3 ~ /^\/var\/lib\/kubelet/ {print $3}' | sort -r | while read -r m; do
              umount "$m" || true
            done
            rm -rf /etc/rancher/k3s /etc/rancher/node
            rm -rf /var/lib/rancher/k3s /var/lib/kubelet /var/lib/longhorn /var/lib/etcd /var/lib/cni
            touch /var/lib/.k3s-wiped || true
            echo "k3s data wiped."
            ;;
          *)
            echo "Aborted."
            ;;
        esac
      '')
    ];
  };
}
