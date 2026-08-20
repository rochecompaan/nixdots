set -euo pipefail

resolve_niri_socket() {
  if [[ -n "${NIRI_SOCKET:-}" && -S "$NIRI_SOCKET" ]]; then
    return 0
  fi

  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$UID}"
  local socket
  local -a sockets=()

  shopt -s nullglob
  for socket in "$runtime_dir"/niri.*.sock; do
    [[ -S "$socket" ]] && sockets+=("$socket")
  done
  shopt -u nullglob

  case "${#sockets[@]}" in
    1)
      export NIRI_SOCKET="${sockets[0]}"
      ;;
    0)
      printf 'No Niri socket found in %s. Start Niri and try again.\n' \
        "$runtime_dir" >&2
      return 1
      ;;
    *)
      printf 'Multiple Niri sockets found in %s. Set NIRI_SOCKET to one of:\n' \
        "$runtime_dir" >&2
      printf '  %s\n' "${sockets[@]}" >&2
      return 1
      ;;
  esac
}

resolve_niri_socket

# Give niri a moment to finish creating initial workspaces.
sleep 1

niri-firefox-launcher launch-profile --workspace 2 --profile default
niri-firefox-launcher launch-profile --workspace 6 --profile clubhouse
niri-firefox-launcher launch-profile --workspace 6 --profile clubhouse_prod
niri-firefox-launcher launch-profile --workspace 7 --profile siyavula
niri-firefox-launcher launch-profile --workspace 7 --profile mycity
niri-firefox-launcher launch-profile --workspace 7 --profile homelab
niri-firefox-launcher launch-profile --workspace 7 --profile sixfeetup
niri-firefox-launcher launch-profile --workspace 8 --profile croprun
niri-firefox-launcher launch-profile --workspace 8 --profile agibase

niri-firefox-launcher focus-workspace --workspace 2 || true
