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

declare -Ar profile_workspaces=(
  [default]=2
  [clubhouse]=6
  [clubhouse_prod]=6
  [siyavula]=7
  [mycity]=7
  [sixfeetup]=7
  [croprun]=8
  [agibase]=8
  [homelab]=8
)

profiles=("$@")
if (( ${#profiles[@]} == 0 )); then
  profiles=(
    default
    clubhouse
    clubhouse_prod
    siyavula
    mycity
    sixfeetup
    croprun
    agibase
    homelab
  )
fi

for profile in "${profiles[@]}"; do
  if [[ -z "${profile_workspaces[$profile]+known}" ]]; then
    printf 'Unknown Firefox profile: %s\n' "$profile" >&2
    exit 1
  fi
done

for profile in "${profiles[@]}"; do
  niri-firefox-launcher launch-profile \
    --workspace "${profile_workspaces[$profile]}" \
    --profile "$profile"
done

niri-firefox-launcher focus-workspace --workspace 2 || true
