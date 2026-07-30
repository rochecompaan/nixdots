set -euo pipefail

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
