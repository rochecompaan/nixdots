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
if [[ "$*" == "launch-profile --workspace 2 --profile default" ]]; then
  printf 'socket|%s\n' "${NIRI_SOCKET-}" >>"$CAPTURE"
fi
printf 'launcher' >>"$CAPTURE"
printf '|%s' "$@" >>"$CAPTURE"
printf '\n' >>"$CAPTURE"
EOF

cat >"$tmp/bin/niri" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/"*

make_socket() {
  local path="$1"
  python3 - "$path" <<'PY'
import socket
import sys

socket_path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX)
sock.bind(socket_path)
sock.close()
PY
}

assert_success() {
  local expected_socket="$1"
  shift
  : >"$CAPTURE"
  "$@"

  cat >"$tmp/want" <<EOF
sleep|1
socket|$expected_socket
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
}

valid_runtime="$tmp/valid"
mkdir -p "$valid_runtime"
valid_socket="$valid_runtime/niri.valid.sock"
make_socket "$valid_socket"
assert_success "$valid_socket" env \
  PATH="$tmp/bin:$PATH" \
  XDG_RUNTIME_DIR="$valid_runtime" \
  NIRI_SOCKET="$valid_socket" \
  bash "$script_dir/firefox-profiles.sh"

unset_runtime="$tmp/unset"
mkdir -p "$unset_runtime"
unset_socket="$unset_runtime/niri.only.sock"
make_socket "$unset_socket"
assert_success "$unset_socket" env -u NIRI_SOCKET \
  PATH="$tmp/bin:$PATH" \
  XDG_RUNTIME_DIR="$unset_runtime" \
  bash "$script_dir/firefox-profiles.sh"

stale_runtime="$tmp/stale"
mkdir -p "$stale_runtime"
stale_socket="$stale_runtime/niri.current.sock"
make_socket "$stale_socket"
assert_success "$stale_socket" env \
  PATH="$tmp/bin:$PATH" \
  XDG_RUNTIME_DIR="$stale_runtime" \
  NIRI_SOCKET="$stale_runtime/niri.old.sock" \
  bash "$script_dir/firefox-profiles.sh"

empty_runtime="$tmp/empty"
mkdir -p "$empty_runtime"
: >"$CAPTURE"
if env -u NIRI_SOCKET \
  PATH="$tmp/bin:$PATH" \
  XDG_RUNTIME_DIR="$empty_runtime" \
  bash "$script_dir/firefox-profiles.sh" >"$tmp/empty.out" 2>"$tmp/empty.err"; then
  echo "expected the no-socket case to fail" >&2
  exit 1
fi
printf 'No Niri socket found in %s. Start Niri and try again.\n' \
  "$empty_runtime" >"$tmp/empty.want"
diff -u "$tmp/empty.want" "$tmp/empty.err"
[[ ! -s "$CAPTURE" ]]

multiple_runtime="$tmp/multiple"
mkdir -p "$multiple_runtime"
first_socket="$multiple_runtime/niri.first.sock"
second_socket="$multiple_runtime/niri.second.sock"
make_socket "$first_socket"
make_socket "$second_socket"
: >"$CAPTURE"
if env -u NIRI_SOCKET \
  PATH="$tmp/bin:$PATH" \
  XDG_RUNTIME_DIR="$multiple_runtime" \
  bash "$script_dir/firefox-profiles.sh" >"$tmp/multiple.out" 2>"$tmp/multiple.err"; then
  echo "expected the multiple-socket case to fail" >&2
  exit 1
fi
cat >"$tmp/multiple.want" <<EOF
Multiple Niri sockets found in $multiple_runtime. Set NIRI_SOCKET to one of:
  $first_socket
  $second_socket
EOF
diff -u "$tmp/multiple.want" "$tmp/multiple.err"
[[ ! -s "$CAPTURE" ]]
