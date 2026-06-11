set -euo pipefail

window_ids() {
  niri msg --json windows | jq -r '.[].id' | LC_ALL=C sort
}

new_window_ids_since() {
  LC_ALL=C comm -13 "$1" <(window_ids)
}

workspace_output() {
  workspace="$1"
  niri msg --json workspaces | jq -r --arg workspace "$workspace" '
    .[]
    | select(.name == $workspace)
    | .output
  ' | head -n 1
}

workspace_index() {
  workspace="$1"
  output="$2"
  niri msg --json workspaces | jq -r --arg workspace "$workspace" --arg output "$output" '
    .[]
    | select(.name == $workspace and .output == $output)
    | .idx
  ' | head -n 1
}

workspace_reference() {
  workspace="$1"
  output="$2"
  index="$(workspace_index "$workspace" "$output")"

  if [ -n "$index" ] && [ "$index" != "null" ]; then
    echo "$index"
  else
    echo "$workspace"
  fi
}

focus_profile_workspace() {
  output="$1"
  workspace_ref="$2"

  if [ -n "$output" ] && [ "$output" != "null" ]; then
    niri msg action focus-monitor "$output" || true
  fi

  niri msg action focus-workspace "$workspace_ref" || true
}

resolve_profile_workspace() {
  workspace="$1"
  output="$(workspace_output "$workspace")"
  workspace_ref="$(workspace_reference "$workspace" "$output")"
  echo "$output:$workspace_ref"
}

focus_profile_workspace_by_name() {
  target="$(resolve_profile_workspace "$1")"
  focus_profile_workspace "${target%:*}" "${target#*:}"
}

launch_profile() {
  workspace="$1"
  profile="$2"
  target="$(resolve_profile_workspace "$workspace")"
  output="${target%:*}"
  workspace_ref="${target#*:}"
  before="$(mktemp)"

  focus_profile_workspace "$output" "$workspace_ref"
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
    if [ -n "$output" ] && [ "$output" != "null" ]; then
      niri msg action move-window-to-monitor --id "$window_id" "$output" || true
    fi
    niri msg action move-window-to-workspace --window-id "$window_id" --focus false "$workspace_ref" || true
  done

  rm -f "$before"
}

# Give niri a moment to finish creating initial workspaces.
sleep 1

launch_profile 2 default
launch_profile 6 clubhouse
launch_profile 6 clubhouse_prod
launch_profile 7 siyavula
launch_profile 7 mycity
launch_profile 7 homelab
launch_profile 7 sixfeetup
launch_profile 8 croprun
launch_profile 8 agibase

focus_profile_workspace_by_name 2 || true
