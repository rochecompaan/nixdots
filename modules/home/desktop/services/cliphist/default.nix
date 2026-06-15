{
  lib,
  pkgs,
  ...
}:
let
  cliphistWatch = pkgs.writeShellApplication {
    name = "cliphist-watch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.wl-clipboard
    ];
    text = ''
      mime_type="$1"
      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

      for _ in {1..30}; do
        while IFS='=' read -r name value; do
          case "$name" in
            WAYLAND_DISPLAY|DISPLAY|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP|NIRI_SOCKET)
              export "$name=$value"
              ;;
          esac
        done < <(systemctl --user show-environment)

        if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
          wayland_socket="$WAYLAND_DISPLAY"
          case "$wayland_socket" in
            /*) ;;
            *) wayland_socket="$runtime_dir/$wayland_socket" ;;
          esac

          if [ -S "$wayland_socket" ]; then
            exec wl-paste --type "$mime_type" --watch ${lib.getExe pkgs.cliphist} store
          fi
        fi

        sleep 1
      done

      echo "Timed out waiting for WAYLAND_DISPLAY before starting cliphist ($mime_type)" >&2
      exit 1
    '';
  };

  mkCliphistService = description: mimeType: {
    Unit = {
      Description = description;
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${cliphistWatch}/bin/cliphist-watch ${mimeType}";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
in
{
  systemd.user.services = {
    cliphist = mkCliphistService "Clipboard history (text)" "text";
    cliphist-images = mkCliphistService "Clipboard history (image)" "image";
  };
}
