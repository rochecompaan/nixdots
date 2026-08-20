# Manual Niri Firefox Profiles Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install `niri-firefox-profiles` on the user `PATH` and recover when `NIRI_SOCKET` is unset or names a missing socket.

**Architecture:** Keep the existing Nix-generated wrapper and Niri autostart entry. Add socket selection to its shell source, then expose the same wrapper through `home.packages`.

**Tech Stack:** Home Manager, Nix, Bash, Python 3 test helper, Git

## Global Constraints

- Work only in `/home/roche/nixdots/.worktrees/niri-firefox-profiles-command` on `feat/niri-firefox-profiles-command`.
- Keep a valid `NIRI_SOCKET` unchanged.
- Recover only when one Unix socket matches `niri.*.sock` in the runtime directory.
- Stop before any Firefox launch when no socket or multiple sockets match.
- Keep all Firefox profile names, workspace assignments, launch order, and the Niri autostart entry unchanged.
- Do not expose `niri-firefox-launcher` through `home.packages`.
- Do not change the Go launcher.
- Treat an existing Unix socket file as valid. Detection of an unresponsive server is outside this change.
- Add behavior tests for socket selection. Do not add a test that only asserts the static `home.packages` value.
- Use direct Nix build and activation checks for the package exposure.

---

### Task 1: Recover a missing or stale Niri socket

**Files:**
- Modify: `modules/home/desktop/wayland/niri/config/firefox-profiles_test.sh`
- Modify: `modules/home/desktop/wayland/niri/config/firefox-profiles.sh:1-4`

**Interfaces:**
- Consumes: `NIRI_SOCKET`, `XDG_RUNTIME_DIR`, Bash `UID`, and Unix socket files named `niri.*.sock`.
- Produces: `resolve_niri_socket`, which exports one valid `NIRI_SOCKET` or returns a nonzero status before profile launch.

- [ ] **Step 1: Replace the shell test with failing socket-selection cases**

Replace `modules/home/desktop/wayland/niri/config/firefox-profiles_test.sh` with:

```bash
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
```

- [ ] **Step 2: Run the shell test and observe the expected failure**

Run:

```bash
bash modules/home/desktop/wayland/niri/config/firefox-profiles_test.sh
```

Expected: FAIL in the unset-socket case. The captured line contains `socket|` instead of the only socket path.

- [ ] **Step 3: Add the minimal socket-selection function**

Insert this code after `set -euo pipefail` in `modules/home/desktop/wayland/niri/config/firefox-profiles.sh`:

```bash
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
```

Keep the startup delay and all launcher calls after this function.

- [ ] **Step 4: Run the shell test and make sure that all cases pass**

Run:

```bash
bash modules/home/desktop/wayland/niri/config/firefox-profiles_test.sh
```

Expected: exit 0 with no output.

- [ ] **Step 5: Run the existing Go launcher tests**

Run:

```bash
cd modules/home/desktop/wayland/niri/firefox-launcher
go test ./...
cd -
```

Expected: both Go packages report `ok`.

- [ ] **Step 6: Commit the socket recovery**

```bash
git add \
  modules/home/desktop/wayland/niri/config/firefox-profiles.sh \
  modules/home/desktop/wayland/niri/config/firefox-profiles_test.sh
git commit -m "fix(niri): recover stale Firefox launcher socket"
```

---

### Task 2: Install the manual profiles command

**Files:**
- Modify: `modules/home/desktop/wayland/niri/config/autostart.nix:19-29`

**Interfaces:**
- Consumes: the existing `firefoxProfiles` derivation from `pkgs.writeShellApplication`.
- Produces: `niri-firefox-profiles` in the Home Manager `home-path/bin` directory and the interactive user `PATH`.

- [ ] **Step 1: Add the wrapper to `home.packages`**

Change the module body to:

```nix
in
{
  home.packages = [ firefoxProfiles ];

  xdg.configFile."niri/config.kdl".text = ''
    // Autostart common desktop components
    spawn-at-startup "1password"
    spawn-at-startup "nm-applet"
    spawn-at-startup "blueman-applet"
    spawn-at-startup "element-desktop" "--hidden"
    spawn-at-startup "nextcloud" "--background"
    spawn-at-startup "${noctalia}"
    spawn-at-startup "${firefoxProfiles}/bin/niri-firefox-profiles"
  '';
}
```

Do not add `firefoxLauncher` to `home.packages`.

- [ ] **Step 2: Format the Nix module**

Run:

```bash
nixfmt modules/home/desktop/wayland/niri/config/autostart.nix
```

Expected: exit 0.

- [ ] **Step 3: Build the affected Home Manager activation package**

Run:

```bash
out="$(nix build \
  '.#homeConfigurations."roche@kipchoge".activationPackage' \
  --no-link \
  --print-out-paths)"
test -x "$out/home-path/bin/niri-firefox-profiles"
printf '%s\n' "$out/home-path/bin/niri-firefox-profiles"
```

Expected: exit 0 and one store path that ends with `/home-path/bin/niri-firefox-profiles`.

- [ ] **Step 4: Run the focused regression checks**

Run:

```bash
bash modules/home/desktop/wayland/niri/config/firefox-profiles_test.sh
(
  cd modules/home/desktop/wayland/niri/firefox-launcher
  go test ./...
)
```

Expected: the shell test exits 0 with no output. Both Go packages report `ok`.

- [ ] **Step 5: Commit the package exposure**

```bash
git add modules/home/desktop/wayland/niri/config/autostart.nix
git commit -m "feat(niri): expose Firefox profiles command"
```

- [ ] **Step 6: Activate the Home Manager profile**

Run:

```bash
home-manager switch --flake '.#roche@kipchoge'
```

Expected: exit 0 with no activation error.

- [ ] **Step 7: Make sure that the command is available**

Run:

```bash
command_path="$(command -v niri-firefox-profiles)"
test -n "$command_path"
test -x "$command_path"
printf '%s\n' "$command_path"
```

Expected: exit 0 and a path in the active Home Manager profile.

- [ ] **Step 8: Make sure that the branch is clean**

Run:

```bash
git status --short
```

Expected: no output.
