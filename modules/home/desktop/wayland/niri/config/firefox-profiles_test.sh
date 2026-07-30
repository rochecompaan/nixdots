#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export CAPTURE="$tmp/calls"

cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep' >>"$CAPTURE"
printf '|%s' "$@" >>"$CAPTURE"
printf '\n' >>"$CAPTURE"
EOF

cat >"$tmp/bin/niri-firefox-launcher" <<'EOF'
#!/usr/bin/env bash
printf 'launcher' >>"$CAPTURE"
printf '|%s' "$@" >>"$CAPTURE"
printf '\n' >>"$CAPTURE"
EOF

cat >"$tmp/bin/niri" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/"*

PATH="$tmp/bin:$PATH" bash "$script_dir/firefox-profiles.sh"

cat >"$tmp/want" <<'EOF'
sleep|1
launcher|launch-profile|--workspace|2|--profile|default
launcher|launch-profile|--workspace|6|--profile|clubhouse
launcher|launch-profile|--workspace|6|--profile|clubhouse_prod
launcher|launch-profile|--workspace|7|--profile|siyavula
launcher|launch-profile|--workspace|7|--profile|mycity
launcher|launch-profile|--workspace|7|--profile|homelab
launcher|launch-profile|--workspace|7|--profile|sixfeetup
launcher|launch-profile|--workspace|8|--profile|croprun
launcher|launch-profile|--workspace|8|--profile|agibase
launcher|focus-workspace|--workspace|2
EOF

diff -u "$tmp/want" "$CAPTURE"
