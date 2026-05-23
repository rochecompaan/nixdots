set -euo pipefail

window_ids() {
  niri msg --json windows | jq -r '.[].id' | sort -n
}

new_window_ids_since() {
  comm -13 "$1" <(window_ids)
}

launch_profile() {
  workspace="$1"
  profile="$2"
  before="$(mktemp)"

  window_ids > "$before"
  firefox --new-instance -P "$profile" >/dev/null 2>&1 &

  deadline=$((SECONDS + 15))
  saw_window=0
  while ((SECONDS < deadline)); do
    if [ -n "$(new_window_ids_since "$before")" ]; then
      saw_window=1
      break
    fi
    sleep 0.25
  done

  # Let Firefox session restore map additional windows before moving them.
  if ((saw_window)); then
    sleep 2
  fi

  new_window_ids_since "$before" | while read -r window_id; do
    [ -n "$window_id" ] || continue
    niri msg action move-window-to-workspace --window-id "$window_id" --focus false "$workspace" || true
  done

  rm -f "$before"
}

# Give niri a moment to finish creating initial workspaces.
sleep 1

launch_profile 2 default
launch_profile 6 clubhouse
launch_profile 7 siyavula
launch_profile 7 mycity
launch_profile 7 homelab
launch_profile 7 sixfeetup
launch_profile 8 croprun

niri msg action focus-workspace 2 || true
