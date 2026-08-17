# OpenWRT Ziti r6 Resolver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release `ziti-edge-tunnel` `1.15.1-r6` with owned dnsmasq UCI rules that send `ha.compaan` to Ziti DNS and guard other private names.

**Architecture:** A focused POSIX shell helper manages two dnsmasq `server` list values and two ownership flags. Package hooks and the init script call the helper, while focused tests cover helper state, real dnsmasq routing, startup order, and IPK lifecycle contracts.

**Tech Stack:** OpenWRT UCI, dnsmasq, POSIX shell, BusyBox ash, Bash test harnesses, Python DNS stubs, procd, Nix flakes, and opkg/IPK archives

## Global Constraints

- Design source: `docs/specs/2026-08-17-ziti-openwrt-r6-resolver-design.md`.
- Work only in `/home/roche/nixdots/.worktrees/ziti-edge-tunnel-r6`.
- Keep the package version at `1.15.1` and change `PKG_RELEASE` from `5` to `6`.
- Keep `/usr/lib/ziti-edge-tunnel/run-managed` as the procd command.
- Keep `--dns-upstream 127.0.0.1` as the default runtime argument.
- Keep Ziti interception limited to router-originated traffic.
- Manage `/compaan/` and `/ha.compaan/100.64.0.2` through `dhcp.@dnsmasq[0].server`.
- Treat the `ha.compaan` subtree as reserved for Ziti because dnsmasq domain rules include descendants.
- Store ownership in `ziti-edge-tunnel.main.dnsmasq_compaan_guard_owned` and `dnsmasq_ha_forward_owned`.
- Use `/tmp/lock/ziti-edge-tunnel-dnsmasq.lock` for resolver changes.
- Apply the CA helper owner, mode, symlink, path, file-descriptor, and inode checks to the new lock.
- Keep dnsmasq rules during Ziti stop, service disable, and `PKG_UPGRADE=1` operations.
- Remove only package-owned rules during final package removal.
- Reload dnsmasq only after a committed rule change.
- Never stop or restart Ziti while the dnsmasq lock is held.
- Keep the existing CA helper and CA lifecycle behavior.
- Keep `modules/nixos/core/certs/compaan-ca.crt` as the only tracked CA source.
- Do not manage `/etc/hosts`, HAProxy, Traefik, Home Assistant, Kubernetes, DHCP ranges, or firewall zones.
- Do not expose JWTs, identities, credentials, private keys, or webhook paths.
- Do not contact the router, a production Ziti service, or a production webhook during tests.
- Use TDD for helper behavior, startup behavior, lifecycle behavior, and package validation.
- Use direct verification for static release values, Nix text, documentation, and configuration defaults.
- Run behavior tests under Bash and BusyBox ash where the plan specifies both shells.
- Keep exactly one writing agent active in this worktree.
- Sign every commit with `git commit -S`.
- Never bypass hooks or commit signing.
- Do not push.
- Do not create Intervals timers or entries for this repository.

## File Map

| Path | Responsibility |
| --- | --- |
| `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-dnsmasq` | Own, restore, and remove the two UCI server values under a secure lock. |
| `nix/packages/ziti-edge-tunnel-openwrt/tests/update-dnsmasq-test.sh` | Exercise helper state transitions, failures, retries, and lock security under Bash and BusyBox ash. |
| `nix/packages/ziti-edge-tunnel-openwrt/tests/dnsmasq-test.sh` | Run real dnsmasq and isolated DNS stubs to prove routing behavior. |
| `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel` | Call resolver `ensure` before the enabled check and before procd registration. |
| `nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh` | Prove resolver preparation order and fail-closed startup under Bash and BusyBox ash. |
| `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel` | Provide `0` defaults for both ownership flags on new installations. |
| `nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile` | Build r6, depend on dnsmasq, install the helper, and run lifecycle actions. |
| `nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh` | Validate the r6 dependency, helper, exact payload, and lifecycle behavior. |
| `nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh` | Prove that IPK validation rejects a missing resolver helper. |
| `modules/packages/ziti-edge-tunnel-openwrt.nix` | Expose helper, routing, service, and IPK flake checks with host tools. |
| `docs/ziti-edge-tunnel-openwrt.md` | Document resolver behavior, ownership, failure behavior, and rollback. |

`run-managed`, `update-ca-bundle`, and `nix/packages/ziti-edge-tunnel-openwrt/default.nix` remain unchanged. The generated package tree already copies the only CA source into the build output.

---

### Task 1: Build the owned dnsmasq UCI helper with TDD

**Files:**
- Create: `nix/packages/ziti-edge-tunnel-openwrt/tests/update-dnsmasq-test.sh`
- Create: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-dnsmasq`
- Modify: `modules/packages/ziti-edge-tunnel-openwrt.nix:5-30`

**Interfaces:**
- Consumes: `update-dnsmasq ensure|remove`.
- Consumes: UCI section `dhcp.@dnsmasq[0]` of type `dnsmasq`.
- Consumes: UCI section `ziti-edge-tunnel.main` of type `ziti`.
- Consumes: environment overrides `ZITI_DNSMASQ_UCI`, `ZITI_DNSMASQ_INIT`, `ZITI_DNSMASQ_LOCK`, and `ZITI_DNSMASQ_LOCK_OWNER`.
- Produces: server value `/compaan/`.
- Produces: server value `/ha.compaan/100.64.0.2`.
- Produces: ownership options with exact values `0` or `1`.
- Produces: one dnsmasq reload after one or more committed rule changes.
- Produces: flake check `checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-helper`.

- [ ] **Step 1: Create the helper test harness and its stateful UCI mock**

Create `update-dnsmasq-test.sh` with this entrypoint and shell loop:

```bash
#!/usr/bin/env bash
set -euo pipefail

helper=${1:?usage: update-dnsmasq-test.sh HELPER [SHELL ...]}
shift
shells=("$@")
[ "${#shells[@]}" -gt 0 ] || shells=(bash)

guard=/compaan/
forward=/ha.compaan/100.64.0.2
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_value() {
  local expected=$1 file=$2
  [[ $(cat "$file") = "$expected" ]] ||
    fail "$file does not contain: $expected"
}

assert_log_count() {
  local expected=$1 pattern=$2 file=$3
  local actual
  actual=$(grep -cF -- "$pattern" "$file" 2>/dev/null || true)
  [[ $actual = "$expected" ]] ||
    fail "$file has $actual copies of $pattern, expected $expected"
}

run_case() {
  local shell_cmd=$1 name=$2 case_function=$3
  local shell_label=${shell_cmd//[^a-zA-Z0-9]/_}
  local root="$test_root/$shell_label/$name"
  new_fixture "$root"
  "$case_function" "$shell_cmd" "$root"
  case_count=$((case_count + 1))
}

case_count=0
```

Inside the harness, write `mock-uci.py` into each fixture. Use one committed JSON file and one staged JSON file per UCI package.

The mock must implement these exact commands:

```text
uci -q get dhcp.@dnsmasq[0]
uci -q get dhcp.@dnsmasq[0].server
uci -q get ziti-edge-tunnel.main
uci -q get ziti-edge-tunnel.main.dnsmasq_compaan_guard_owned
uci -q get ziti-edge-tunnel.main.dnsmasq_ha_forward_owned
uci set ziti-edge-tunnel.main.dnsmasq_compaan_guard_owned=1
uci set ziti-edge-tunnel.main.dnsmasq_ha_forward_owned=1
uci add_list dhcp.@dnsmasq[0].server=/compaan/
uci add_list dhcp.@dnsmasq[0].server=/ha.compaan/100.64.0.2
uci del_list dhcp.@dnsmasq[0].server=/compaan/
uci del_list dhcp.@dnsmasq[0].server=/ha.compaan/100.64.0.2
uci commit dhcp
uci commit ziti-edge-tunnel
uci revert dhcp
uci revert ziti-edge-tunnel
```

Use this persisted state shape:

```json
{
  "dhcp": {
    "dhcp.@dnsmasq[0]": "dnsmasq",
    "dhcp.@dnsmasq[0].server": []
  },
  "ziti-edge-tunnel": {
    "ziti-edge-tunnel.main": "ziti"
  }
}
```

The mock must read these failure controls:

```text
MOCK_UCI_FAIL_ALWAYS='get dhcp.@dnsmasq[0]'
MOCK_UCI_FAIL_ONCE='commit dhcp'
```

For example, `MOCK_UCI_FAIL_ONCE='commit dhcp'` must fail the first matching call with exit `70`. It must create a marker before it returns so rollback commits can run.

Log every mock command to `$MOCK_UCI_LOG`. Keep mutations in the staged package until `commit`. Delete only that package stage during `revert`.

Create a mock dnsmasq init script with this contract:

```sh
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_DNSMASQ_LOG"
if [ "${MOCK_DNSMASQ_RELOAD_RESULT:-success}" = fail ]; then
        exit 71
fi
if [ "${MOCK_DNSMASQ_RELOAD_FAIL_ONCE:-0}" = 1 ] &&
        [ ! -e "$MOCK_DNSMASQ_ROOT/reload-failed" ]; then
        : >"$MOCK_DNSMASQ_ROOT/reload-failed"
        exit 71
fi
```

Run the helper with these environment values:

```bash
run_helper() {
  local shell_cmd=$1 root=$2 action=$3
  local -a shell_words
  read -r -a shell_words <<<"$shell_cmd"
  MOCK_UCI_ROOT="$root/uci" \
  MOCK_UCI_LOG="$root/uci.log" \
  MOCK_DNSMASQ_LOG="$root/dnsmasq.log" \
  MOCK_DNSMASQ_ROOT="$root" \
  ZITI_DNSMASQ_UCI="$root/bin/uci" \
  ZITI_DNSMASQ_INIT="$root/bin/dnsmasq" \
  ZITI_DNSMASQ_LOCK="$root/update.lock" \
  ZITI_DNSMASQ_LOCK_OWNER="${TEST_DNSMASQ_LOCK_OWNER:-$(id -u)}" \
    "${shell_words[@]}" "$helper" "$action"
}
```

- [ ] **Step 2: Add exact helper behavior cases**

Add these cases for each shell in `shells`:

| Case | Initial committed state | Action | Required result |
| --- | --- | --- | --- |
| `add-and-idempotent` | no rules, no flags | `ensure` twice | two rules, both flags `1`, one reload total |
| `external-both` | both rules, no flags | `ensure` | rules unchanged, flags absent or `0`, no reload |
| `external-guard` | guard only, no flags | `ensure` | guard flag `0`, forward flag `1`, one reload |
| `external-forward` | forward only, no flags | `ensure` | guard flag `1`, forward flag `0`, one reload |
| `restore-guard` | guard flag `1`, forward flag `1`, forward rule only | `ensure` | both rules present, one reload |
| `restore-forward` | both flags `1`, guard rule only | `ensure` | both rules present, one reload |
| `remove-owned` | both rules and both flags `1` | `remove` | no rules, both flags `0`, one reload |
| `remove-mixed` | both rules, guard flag `0`, forward flag `1` | `remove` | guard remains, forward removed, flags `0`, one reload |
| `remove-stale-owner` | no rules, both flags `1` | `remove` | flags `0`, no reload |
| `unchanged-remove` | external rules, flags `0` | `remove` | state unchanged, no reload |
| `invalid-flag` | guard flag `yes` | `ensure` | nonzero, state unchanged, no reload |
| `missing-dnsmasq-section` | no dnsmasq section | `ensure` | nonzero, no ownership change, no reload |
| `missing-ziti-section` | no package section | `ensure` | nonzero, no rule change, no reload |
| `uci-read-error` | valid state | fail `get dhcp.@dnsmasq[0]` | nonzero, unchanged, no reload |
| `server-list-read-error` | an existing server value | fail server-list `get` | nonzero, unchanged, no reload |
| `guard-flag-read-error` | explicit guard flag `0` | fail guard-flag `get` | nonzero, unchanged, no reload |
| `forward-flag-read-error` | explicit forward flag `0` | fail forward-flag `get` | nonzero, unchanged, no reload |
| `uci-write-error` | no rules | fail first `add_list` | nonzero, committed rules unchanged, no reload |
| `ownership-commit-error` | no rules | fail `commit ziti-edge-tunnel` | nonzero, no committed rule, no reload |
| `rule-commit-error` | no rules | fail `commit dhcp` | nonzero, flags stay `1`, no committed rule, no reload |
| `ensure-reload-error` | no rules | fail reload | nonzero, prior rules restored, flags stay `1`, rollback reload attempted |
| `remove-reload-error` | owned rules | fail first reload only | nonzero, owned rules restored, flags stay `1`, rollback reload succeeds |
| `ensure-rollback-commit-error` | no rules | fail reload, then rollback commit | nonzero, staged DHCP state reverted |
| `remove-rollback-commit-error` | owned rules | fail reload, then rollback commit | nonzero, staged DHCP state reverted |
| `unknown-action` | valid state | `invalid` | exit `2`, no UCI command, no reload |

For the reload rollback cases, make the dnsmasq mock fail once. Record a marker in the fixture before exit `71`, then let the rollback reload succeed.

Assert exact state through the mock JSON. Do not infer state only from log lines.

- [ ] **Step 3: Add secure-lock regression cases**

Copy the CA helper lock attack patterns into the new harness. Use the dnsmasq lock path and dnsmasq error text.

Cover these exact cases under both shells:

```text
existing symbolic-link lock
existing directory at lock path
lock mode 0644
wrong expected owner
path inode replaced during open
second helper waits for the first helper lock holder
```

For the inode replacement case, put a mock `ls` command first in `PATH`. On the first `/proc/self/fd/9` inspection, replace the lock path with a new regular file before delegating to the real `ls`.

Each insecure-lock case must prove that the UCI log is empty.

After all case functions, add this exact runner:

```bash
for shell_cmd in "${shells[@]}"; do
  run_case "$shell_cmd" add-and-idempotent case_add_and_idempotent
  run_case "$shell_cmd" external-both case_external_both
  run_case "$shell_cmd" external-guard case_external_guard
  run_case "$shell_cmd" external-forward case_external_forward
  run_case "$shell_cmd" restore-guard case_restore_guard
  run_case "$shell_cmd" restore-forward case_restore_forward
  run_case "$shell_cmd" remove-owned case_remove_owned
  run_case "$shell_cmd" remove-mixed case_remove_mixed
  run_case "$shell_cmd" remove-stale-owner case_remove_stale_owner
  run_case "$shell_cmd" unchanged-remove case_unchanged_remove
  run_case "$shell_cmd" invalid-flag case_invalid_flag
  run_case "$shell_cmd" missing-dnsmasq-section case_missing_dnsmasq_section
  run_case "$shell_cmd" missing-ziti-section case_missing_ziti_section
  run_case "$shell_cmd" uci-read-error case_uci_read_error
  run_case "$shell_cmd" ensure-rollback-commit-error case_ensure_rollback_commit_error
  run_case "$shell_cmd" remove-rollback-commit-error case_remove_rollback_commit_error
  run_case "$shell_cmd" server-list-read-error case_server_list_read_error
  run_case "$shell_cmd" guard-flag-read-error case_guard_flag_read_error
  run_case "$shell_cmd" forward-flag-read-error case_forward_flag_read_error
  run_case "$shell_cmd" uci-write-error case_uci_write_error
  run_case "$shell_cmd" ownership-commit-error case_ownership_commit_error
  run_case "$shell_cmd" rule-commit-error case_rule_commit_error
  run_case "$shell_cmd" ensure-reload-error case_ensure_reload_error
  run_case "$shell_cmd" remove-reload-error case_remove_reload_error
  run_case "$shell_cmd" unknown-action case_unknown_action
  run_case "$shell_cmd" lock-symlink case_lock_symlink
  run_case "$shell_cmd" lock-directory case_lock_directory
  run_case "$shell_cmd" lock-mode case_lock_mode
  run_case "$shell_cmd" lock-owner case_lock_owner
  run_case "$shell_cmd" lock-inode case_lock_inode
  run_case "$shell_cmd" lock-serialization case_lock_serialization
done

printf 'dnsmasq helper tests: %s passed for %s shell(s)\n' \
  "$case_count" "${#shells[@]}"
```

- [ ] **Step 4: Run the helper test against a failing executable**

Run:

```bash
nix shell nixpkgs#{bash,busybox,python3,util-linux} -c \
  bash nix/packages/ziti-edge-tunnel-openwrt/tests/update-dnsmasq-test.sh \
  /bin/false bash "$(nix build nixpkgs#busybox --no-link --print-out-paths)/bin/busybox ash"
```

Expected: FAIL in `add-and-idempotent` because `/bin/false` creates no UCI state.

- [ ] **Step 5: Create the minimal POSIX helper**

Create `update-dnsmasq` with this header and constants:

```sh
#!/bin/sh
set -eu

UCI=${ZITI_DNSMASQ_UCI:-uci}
DNSMASQ_INIT=${ZITI_DNSMASQ_INIT:-/etc/init.d/dnsmasq}
DNSMASQ_LOCK=${ZITI_DNSMASQ_LOCK:-/tmp/lock/ziti-edge-tunnel-dnsmasq.lock}
DNSMASQ_LOCK_OWNER=${ZITI_DNSMASQ_LOCK_OWNER:-0}
DNSMASQ_SECTION='dhcp.@dnsmasq[0]'
ZITI_SECTION='ziti-edge-tunnel.main'
GUARD='/compaan/'
FORWARD='/ha.compaan/100.64.0.2'
GUARD_FLAG='dnsmasq_compaan_guard_owned'
FORWARD_FLAG='dnsmasq_ha_forward_owned'

action=${1:-}
case "$action" in
        ensure | remove) ;;
        *)
                printf 'usage: %s ensure|remove\n' "$0" >&2
                exit 2
                ;;
esac

fail() {
        printf 'ziti-edge-tunnel dnsmasq: %s\n' "$*" >&2
        exit 1
}
```

Copy the lock validation sequence from `update-ca-bundle`. Replace CA names with dnsmasq names, but keep file descriptor `9` and every security check.

Use these state helpers:

```sh
read_flag() {
        flag_name=$1
        if flag_value=$("$UCI" -q get "$ZITI_SECTION.$flag_name" 2>/dev/null); then
                :
        elif printf '%s\n' "$ziti_listing" |
                grep -F "$ZITI_SECTION.$flag_name=" >/dev/null; then
                fail "cannot read ownership flag $flag_name"
        else
                flag_value=0
        fi
        case "$flag_value" in
                0 | 1) printf '%s\n' "$flag_value" ;;
                *) fail "invalid ownership flag $flag_name: $flag_value" ;;
        esac
}

has_server() {
        wanted=$1
        for server_value in $server_values; do
                [ "$server_value" = "$wanted" ] && return 0
        done
        return 1
}

set_owner() {
        $UCI set "$ZITI_SECTION.$1=$2" || return 1
}

reload_dnsmasq() {
        "$DNSMASQ_INIT" reload
}
```

Before `read_flag`, verify both UCI sections:

```sh
[ "$($UCI -q get "$DNSMASQ_SECTION")" = dnsmasq ] ||
        fail 'dnsmasq UCI section is missing or invalid'
[ "$($UCI -q get "$ZITI_SECTION")" = ziti ] ||
        fail 'ziti-edge-tunnel UCI section is missing or invalid'
```

Read each full UCI section with `uci show` before the optional values. Treat an option as absent only when the section read succeeds and its listing does not contain that option. If `get` fails for an option present in the listing, stop before mutation.

Implement `ensure` in this durable order:

1. Read both flags and the committed server list.
2. Stage `1` only for a missing rule with flag `0`.
3. Commit `ziti-edge-tunnel` before any dnsmasq rule commit.
4. Stage each missing rule with `add_list`.
5. Commit `dhcp` once.
6. Reload dnsmasq once.
7. If reload fails, remove only rules added by this call, commit rollback, and attempt one rollback reload.
8. If a rollback commit fails, revert the staged `dhcp` package before returning an error.
9. Keep newly claimed flags at `1` after rollback.

Implement `remove` in this durable order:

1. Read both flags and the committed server list.
2. Stage `del_list` only for a present rule with flag `1`.
3. Commit `dhcp` once and reload once when a rule changed.
4. If reload fails, restore only rules removed by this call, commit rollback, and attempt one rollback reload.
5. If a rollback commit fails, revert the staged `dhcp` package before returning an error.
6. Keep flags at `1` after rollback.
7. After successful rule removal, set owned flags to `0` and commit `ziti-edge-tunnel` once.
8. Clear a stale `1` flag without reload when its rule is already absent.

On a mutation error before commit, call `uci revert` for the affected package. If rollback commit or rollback reload fails, print a second diagnostic before the final nonzero exit.

Do not call the Ziti init script from this helper.

- [ ] **Step 6: Run the helper harness directly**

Run:

```bash
chmod 0755 nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-dnsmasq
busybox=$(nix build nixpkgs#busybox --no-link --print-out-paths)
nix shell nixpkgs#{bash,python3,util-linux} -c \
  bash nix/packages/ziti-edge-tunnel-openwrt/tests/update-dnsmasq-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-dnsmasq \
  bash "$busybox/bin/busybox ash"
```

Expected: `dnsmasq helper tests: 62 passed for 2 shell(s)`.

- [ ] **Step 7: Wire the focused helper flake check**

Add these bindings to the `let` block in `modules/packages/ziti-edge-tunnel-openwrt.nix`:

```nix
dnsmasq-helper = ../../nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-dnsmasq;
dnsmasq-helper-test = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/update-dnsmasq-test.sh;
```

Add this check after the CA bundle check:

```nix
checks.ziti-edge-tunnel-openwrt-dnsmasq-helper =
  pkgs.runCommand "ziti-edge-tunnel-openwrt-dnsmasq-helper-test"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.busybox
        pkgs.python3
        pkgs.util-linux
      ];
    }
    ''
      bash ${dnsmasq-helper-test} ${dnsmasq-helper} \
        bash "${pkgs.busybox}/bin/busybox ash"
      touch $out
    '';
```

- [ ] **Step 8: Run the focused flake check**

Run:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-helper --no-link
```

Expected: PASS under Bash and BusyBox ash.

- [ ] **Step 9: Commit the helper and behavior tests**

Run:

```bash
git add \
  modules/packages/ziti-edge-tunnel-openwrt.nix \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-dnsmasq \
  nix/packages/ziti-edge-tunnel-openwrt/tests/update-dnsmasq-test.sh
git commit -S -m "feat(ziti): manage OpenWRT dnsmasq rules"
```

Expected: the commit hook passes and Git records a signed commit.

---

### Task 2: Prove routing with a real dnsmasq process

**Files:**
- Create: `nix/packages/ziti-edge-tunnel-openwrt/tests/dnsmasq-test.sh`
- Modify: `modules/packages/ziti-edge-tunnel-openwrt.nix:5-80`

**Interfaces:**
- Consumes: host dnsmasq binary as argument `$1`.
- Consumes: host `python3` from `PATH`.
- Produces: isolated UDP Ziti and public DNS stubs.
- Produces: flake check `checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-routing`.

This test validates external dnsmasq semantics. It does not change package behavior, so it has no artificial red phase.

- [ ] **Step 1: Create the real routing test**

Create this Bash wrapper:

```bash
#!/usr/bin/env bash
set -euo pipefail

dnsmasq=${1:?usage: dnsmasq-test.sh DNSMASQ}
[[ -x $dnsmasq ]] || { printf 'missing dnsmasq: %s\n' "$dnsmasq" >&2; exit 1; }

python3 - "$dnsmasq" <<'PY'
```

In the embedded Python program, implement these parts:

1. Allocate three unused UDP loopback ports for dnsmasq, Ziti, and public DNS.
2. Start one UDP thread per stub.
3. Parse the DNS question name from each packet.
4. Record every received name in a list per stub.
5. Return `100.64.0.4` from the Ziti stub for `ha.compaan`.
6. Return `192.0.2.80` from the public stub for `public.example`.
7. Return NXDOMAIN from a stub for any other received name.
8. Start dnsmasq with no hosts file and no resolv file.
9. Send A queries through dnsmasq with a two-second socket timeout.
10. Terminate dnsmasq and both stub threads in a `finally` block.

Import `os`, `pwd`, `socket`, `struct`, `subprocess`, `threading`, and `time`. Use these exact dnsmasq arguments:

```python
command = [
    dnsmasq,
    "--keep-in-foreground",
    f"--port={dnsmasq_port}",
    "--listen-address=127.0.0.1",
    "--bind-interfaces",
    "--no-hosts",
    "--no-resolv",
    "--log-facility=-",
    "--server=/compaan/",
    f"--server=/ha.compaan/127.0.0.1#{ziti_port}",
    f"--server=127.0.0.1#{public_port}",
    f"--user={pwd.getpwuid(os.getuid()).pw_name}",
]
```

Use DNS response flags `0x8180` for success and `0x8183` for NXDOMAIN. For successful A answers, append this record after the question:

```python
answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton(address)
```

Make these exact assertions:

```python
assert query("ha.compaan") == (0, "100.64.0.4")
assert query("unknown.compaan") == (3, None)
assert query("public.example") == (0, "192.0.2.80")
assert query("child.ha.compaan")[0] == 3
assert ziti_names == ["ha.compaan", "child.ha.compaan"]
assert public_names == ["public.example"]
```

The descendant assertion preserves the approved reserved-subtree behavior. The unknown sibling must not appear in either stub list.

Finish the wrapper with:

```bash
PY
printf 'dnsmasq routing tests: 5 passed\n'
```

- [ ] **Step 2: Run the routing test directly**

Run:

```bash
dnsmasq=$(nix build nixpkgs#dnsmasq --no-link --print-out-paths)
nix shell nixpkgs#{bash,python3} -c \
  bash nix/packages/ziti-edge-tunnel-openwrt/tests/dnsmasq-test.sh \
  "$dnsmasq/bin/dnsmasq"
```

Expected: `dnsmasq routing tests: 5 passed`.

- [ ] **Step 3: Wire the routing flake check**

Add this binding:

```nix
dnsmasq-test = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/dnsmasq-test.sh;
```

Add this check after the helper check:

```nix
checks.ziti-edge-tunnel-openwrt-dnsmasq-routing =
  pkgs.runCommand "ziti-edge-tunnel-openwrt-dnsmasq-routing-test"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.dnsmasq
        pkgs.python3
      ];
    }
    ''
      bash ${dnsmasq-test} ${pkgs.dnsmasq}/bin/dnsmasq
      touch $out
    '';
```

- [ ] **Step 4: Run the routing flake check**

Run:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-routing --no-link
```

Expected: PASS with no external network traffic.

- [ ] **Step 5: Commit the real routing test**

Run:

```bash
git add \
  modules/packages/ziti-edge-tunnel-openwrt.nix \
  nix/packages/ziti-edge-tunnel-openwrt/tests/dnsmasq-test.sh
git commit -S -m "test(ziti): verify OpenWRT dnsmasq routing"
```

Expected: a signed test commit.

---

### Task 3: Prepare dnsmasq before procd registration with TDD

**Files:**
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh:28-117,216-243,474-518`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel:7-18,197-228`

**Interfaces:**
- Consumes: `ZITI_DNSMASQ_HELPER`, default `/usr/lib/ziti-edge-tunnel/update-dnsmasq`.
- Produces: helper call `ensure` before the service enabled check.
- Produces: startup order `dnsmasq`, `ca`, `procd` for an enabled service.
- Produces: no procd instance after a resolver helper failure.

- [ ] **Step 1: Extend the service harness with a resolver helper mock**

Add these fixture values after `ZITI_CA_BUNDLE_HELPER`:

```bash
export ZITI_DNSMASQ_HELPER="$root/bin/update-dnsmasq"
export TEST_DNSMASQ_RESULT=success
export TEST_DNSMASQ_COMMAND="$root/dnsmasq-command"
: >"$TEST_DNSMASQ_COMMAND"
```

Create this mock after the CA helper mock:

```bash
cat >"$ZITI_DNSMASQ_HELPER" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"$TEST_DNSMASQ_COMMAND"
printf 'dnsmasq\n' >>"$TEST_START_ORDER"
[ "${TEST_DNSMASQ_RESULT:-failure}" = success ]
MOCK
chmod 0755 "$ZITI_DNSMASQ_HELPER"
```

- [ ] **Step 2: Write failing startup-order and failure cases**

Replace `case_disabled` with:

```bash
case_disabled() {
  TEST_ENABLED=0
  start_service
  assert_contains "$TEST_DNSMASQ_COMMAND" 'ensure'
  [[ ! -s $root/procd-command ]] || fail 'disabled service started a process'
  [[ ! -s $TEST_CA_COMMAND ]] || fail 'disabled service refreshed the CA bundle'
}
```

Update the success-order assertions:

```bash
[[ $(sed -n '1p' "$TEST_START_ORDER") = dnsmasq ]] ||
  fail 'dnsmasq preparation did not run first'
[[ $(sed -n '2p' "$TEST_START_ORDER") = ca ]] ||
  fail 'CA refresh did not run after dnsmasq preparation'
[[ $(sed -n '3p' "$TEST_START_ORDER") = procd ]] ||
  fail 'procd did not run after preparation'
```

Add this case before the CA failure case:

```bash
case_dnsmasq_prepare_failure_blocks_start() {
  printf '{}\n' >"$TEST_IDENTITY"
  export TEST_DNSMASQ_RESULT=failure
  if start_service; then
    fail 'dnsmasq preparation failure started the service'
  fi
  assert_contains "$TEST_DNSMASQ_COMMAND" 'ensure'
  [[ ! -s $TEST_CA_COMMAND ]] || fail 'CA refresh ran after dnsmasq failure'
  [[ ! -s $root/procd-command ]] || fail 'dnsmasq failure configured procd'
  assert_no_file "$ZITI_RUNTIME_DIR/resolv.conf.before"
}
```

Add this case to the run list:

```bash
run_case dnsmasq-prepare-failure case_dnsmasq_prepare_failure_blocks_start
```

Add dedicated BusyBox ash cases for successful preparation order, disabled-service repair, dnsmasq preparation failure, and stop behavior. Each case must source the shipped init script under BusyBox ash and assert observable command files and ordering. Set `busybox_cases=4`.

- [ ] **Step 3: Run the service check to verify red**

Run:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service --no-link
```

Expected: FAIL because the init script does not call `update-dnsmasq ensure`.

- [ ] **Step 4: Implement fail-closed resolver preparation**

Add the helper path near the CA helper path:

```sh
DNSMASQ_HELPER=${ZITI_DNSMASQ_HELPER:-/usr/lib/ziti-edge-tunnel/update-dnsmasq}
```

Add this function before `refresh_ca_bundle`:

```sh
prepare_dnsmasq() {
        if ! "$DNSMASQ_HELPER" ensure; then
                log 'dnsmasq resolver preparation failed'
                return 1
        fi
}
```

Change the beginning of `start_service` to this order:

```sh
start_service() {
        load_ziti_config || return 1
        prepare_dnsmasq || return 1
        [ "$enabled" -eq 1 ] || return 0
        refresh_ca_bundle || return 1
```

Do not add any `remove` call to `stop_service`, `service_triggers`, or `reload_service`.

- [ ] **Step 5: Run service tests under both shells**

Run:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service --no-link
```

Expected: PASS for the Bash cases and the four dedicated BusyBox ash resolver cases.

- [ ] **Step 6: Run helper and service checks together**

Run:

```bash
nix build \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-helper \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service \
  --no-link
```

Expected: both checks pass.

- [ ] **Step 7: Commit the startup integration**

Run:

```bash
git add \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh
git commit -S -m "fix(ziti): prepare dnsmasq before tunnel start"
```

Expected: a signed behavior commit.

---

### Task 4: Package the r6 helper and lifecycle with TDD

**Files:**
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh:69-178`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh:15-88`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel:1-7`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile:3-36,76-106`
- Modify: `modules/packages/ziti-edge-tunnel-openwrt.nix:31-50`

**Interfaces:**
- Consumes: helper from Task 1.
- Produces: OpenWRT package `1.15.1-r6`.
- Produces: dependency `dnsmasq`.
- Produces: live `postinst` actions `CA ensure` and `dnsmasq ensure`.
- Produces: upgrade `prerm` action `CA remove` without dnsmasq removal.
- Produces: final `prerm` actions `CA remove` and `dnsmasq remove`.

- [ ] **Step 1: Extend IPK paths, dependency, mode, and exact payload checks**

Add the resolver helper path:

```bash
dnsmasq_helper=$tmp/data/usr/lib/ziti-edge-tunnel/update-dnsmasq
```

Add it to the required file loop. Add `dnsmasq` to the dependency loop.

Add this mode assertion:

```bash
[[ $(stat -c %a "$dnsmasq_helper") = 755 ]] || {
  printf 'dnsmasq helper mode is not 0755\n' >&2
  exit 1
}
```

After extraction, compare the exact control archive entries to:

```text
./
./conffiles
./control
./postinst
./postinst-pkg
./prerm
./prerm-pkg
```

Compare the exact data archive entries to:

```text
./
./etc/
./etc/config/
./etc/config/ziti-edge-tunnel
./etc/init.d/
./etc/init.d/ziti-edge-tunnel
./etc/openziti/
./etc/openziti/identities/
./etc/ssl/
./etc/ssl/certs/
./etc/ssl/certs/compaan-ca.crt
./usr/
./usr/bin/
./usr/bin/ziti-edge-tunnel
./usr/lib/
./usr/lib/ziti-edge-tunnel/
./usr/lib/ziti-edge-tunnel/run-managed
./usr/lib/ziti-edge-tunnel/update-ca-bundle
./usr/lib/ziti-edge-tunnel/update-dnsmasq
```

Sort both expected and actual lists before `cmp`. Print a unified diff when a list differs.

- [ ] **Step 2: Extend lifecycle mocks and assertions**

Replace the single lifecycle helper with separate CA and dnsmasq helpers. Each helper must log its kind and first argument with this command:

```sh
printf '%s:%s\n' "$HELPER_KIND" "$1" >>"$LIFECYCLE_LOG"
```

Use these environment paths:

```bash
ZITI_CA_BUNDLE_HELPER="$ca_lifecycle_helper"
ZITI_DNSMASQ_HELPER="$dnsmasq_lifecycle_helper"
```

Add these exact lifecycle cases:

| Case | Environment | Expected log | Expected status |
| --- | --- | --- | --- |
| live postinst | `IPKG_INSTROOT=` | `ca:ensure`, `dnsmasq:ensure` | zero |
| upgrade prerm | `IPKG_INSTROOT= PKG_UPGRADE=1` | `ca:remove` only | zero |
| final prerm | `IPKG_INSTROOT= PKG_UPGRADE=0` | `ca:remove`, `dnsmasq:remove` | zero |
| offline postinst | `IPKG_INSTROOT=$tmp/root` | empty | zero |
| offline prerm | `IPKG_INSTROOT=$tmp/root` | empty | zero |
| CA postinst failure | CA fails | `ca:ensure` only | nonzero |
| dnsmasq postinst failure | dnsmasq fails | both ensure actions | nonzero |
| dnsmasq final-remove failure | dnsmasq fails | both remove actions | nonzero |

The upgrade case proves that resolver rules stay active. The final case proves that package-owned rules receive the `remove` action.

- [ ] **Step 3: Add a validator mutation for the missing resolver helper**

Add this mutator:

```bash
mutate_missing_dnsmasq_helper() {
  rm -f "$1/usr/lib/ziti-edge-tunnel/update-dnsmasq"
}
```

Add this case after the CA helper case:

```bash
run_case missing-dnsmasq-helper mutate_missing_dnsmasq_helper
```

Change the final message to `validator tests: 10 passed`.

- [ ] **Step 4: Set the expected release to r6 in the Nix check**

Change both release arguments from `5` to `6`:

```nix
bash ${verify-ipk} "$ipk" mipsel_24kc 1.15.1 6
bash ${validator-test} "$ipk" ${verify-ipk} 6
```

- [ ] **Step 5: Run the IPK check to verify red**

Run:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk --no-link
```

Expected: FAIL because the package is still r5 and lacks `update-dnsmasq` and `dnsmasq`.

- [ ] **Step 6: Add ownership defaults for new installations**

Add these options after `dns_upstream`:

```text
        option dnsmasq_compaan_guard_owned '0'
        option dnsmasq_ha_forward_owned '0'
```

Do not add rule values to this package configuration. The helper owns rule creation in `/etc/config/dhcp`.

- [ ] **Step 7: Update the OpenWRT package definition**

Make these release and dependency changes:

```make
PKG_RELEASE:=6
```

```make
DEPENDS:=+ca-bundle +dnsmasq +kmod-tun +libatomic +libjson-c +libopenssl +libpcap +libprotobuf-c +libsodium +libstdcpp +libuv +openssl-util +zlib
```

Install the new helper next to the CA helper:

```make
	$(INSTALL_BIN) ./files/usr/lib/ziti-edge-tunnel/update-dnsmasq $(1)/usr/lib/ziti-edge-tunnel/update-dnsmasq
```

Use this `postinst` body:

```make
define Package/ziti-edge-tunnel/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
ca_helper="$${ZITI_CA_BUNDLE_HELPER:-/usr/lib/ziti-edge-tunnel/update-ca-bundle}"
dnsmasq_helper="$${ZITI_DNSMASQ_HELPER:-/usr/lib/ziti-edge-tunnel/update-dnsmasq}"
"$$ca_helper" ensure || exit $$?
"$$dnsmasq_helper" ensure
endef
```

Use this `prerm` body:

```make
define Package/ziti-edge-tunnel/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
ca_helper="$${ZITI_CA_BUNDLE_HELPER:-/usr/lib/ziti-edge-tunnel/update-ca-bundle}"
dnsmasq_helper="$${ZITI_DNSMASQ_HELPER:-/usr/lib/ziti-edge-tunnel/update-dnsmasq}"
"$$ca_helper" remove || exit $$?
[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0
"$$dnsmasq_helper" remove
endef
```

Neither hook can call `/etc/init.d/ziti-edge-tunnel`. OpenWRT default package lifecycle code owns service stop and start operations after custom hooks return.

- [ ] **Step 8: Run the IPK check to verify green**

Run:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk --no-link
```

Expected: PASS for release, dependency, archive paths, ownership, modes, lifecycle actions, binary metadata, CA validation, and validator mutations.

- [ ] **Step 9: Run all focused r6 checks**

Run:

```bash
nix build \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-helper \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-routing \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ca-bundle \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk \
  --no-link
```

Expected: all five checks pass.

- [ ] **Step 10: Verify static configuration directly**

Run:

```bash
grep -Fx "        option dnsmasq_compaan_guard_owned '0'" \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel
grep -Fx "        option dnsmasq_ha_forward_owned '0'" \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel
grep -Fx 'PKG_RELEASE:=6' \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile
grep -F '+dnsmasq' \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile
```

Expected: all four commands find the exact values. These checks replace new automated tests for static configuration text.

- [ ] **Step 11: Commit the r6 package lifecycle**

Run:

```bash
git add \
  modules/packages/ziti-edge-tunnel-openwrt.nix \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh \
  nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh
git commit -S -m "fix(ziti): package OpenWRT r6 resolver lifecycle"
```

Expected: a signed package commit.

---

### Task 5: Document r6 and produce final verification evidence

**Files:**
- Modify: `docs/ziti-edge-tunnel-openwrt.md:57-105`

**Interfaces:**
- Consumes: completed r6 package and focused checks.
- Produces: operator documentation and release evidence.

This task changes documentation and verification commands. The Testing Value Gate excludes a new documentation-content test.

- [ ] **Step 1: Update the resolver documentation**

Add a `## Compaan resolver routing` section after `## Compaan CA trust`.

Include these exact rules:

```text
server=/compaan/
server=/ha.compaan/100.64.0.2
```

Document these facts in short paragraphs:

- `ha.compaan` reaches Ziti DNS and normally resolves to `100.64.0.4`.
- Unknown siblings such as `unknown.compaan` return NXDOMAIN in dnsmasq.
- Public names continue through existing WAN resolvers.
- dnsmasq domain matching reserves descendants of `ha.compaan` for Ziti.
- The rules remain during service stop, disable, and package upgrade.
- Final package removal removes only package-owned rules.
- A failed resolver `ensure` blocks procd registration.
- No-change helper calls do not reload dnsmasq.

Add this supported rollback procedure:

```sh
opkg remove ziti-edge-tunnel
opkg install /tmp/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk
```

State that a direct forced downgrade is unsupported because r5 cannot remove r6 ownership state.

Do not add commands that modify `/etc/hosts`. Do not add production webhook commands.

- [ ] **Step 2: Verify shell syntax under both interpreters**

Run:

```bash
bash -n \
  nix/packages/ziti-edge-tunnel-openwrt/tests/update-dnsmasq-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/tests/dnsmasq-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh \
  nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh
busybox=$(nix build nixpkgs#busybox --no-link --print-out-paths)
"$busybox/bin/busybox" ash -n \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-dnsmasq
"$busybox/bin/busybox" ash -n \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel
```

Expected: all syntax checks exit zero.

- [ ] **Step 3: Verify the single tracked CA source and unchanged managed wrapper**

Run:

```bash
test "$(git ls-files '*compaan-ca.crt')" = \
  modules/nixos/core/certs/compaan-ca.crt
git diff main -- \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/run-managed
grep -F -- '--dns-upstream "$dns_upstream"' \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel
```

Expected: one CA source, no wrapper diff, and the existing DNS upstream argument remains.

- [ ] **Step 4: Run the full focused verification set**

Run:

```bash
nix build \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-helper \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-routing \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ca-bundle \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk \
  .#checks.x86_64-linux.ziti-openwrt-tunnel-script \
  --no-link
```

Expected: all six checks pass.

- [ ] **Step 5: Build r6 and record its SHA-256**

Run:

```bash
out=$(nix build .#ziti-edge-tunnel-openwrt --no-link --print-out-paths)
ipk=$(printf '%s\n' "$out"/*.ipk)
sha256sum "$ipk"
```

Expected: one `1.15.1-r6` IPK and one SHA-256 line. Record the hash in the completion report, not in source documentation.

- [ ] **Step 6: Run the full flake check**

Run:

```bash
nix flake check --accept-flake-config --print-build-logs
```

Expected: all flake checks pass.

- [ ] **Step 7: Review the final diff for scope and secrets**

Run:

```bash
git diff --check main...HEAD
git diff --stat main...HEAD
git status --short
git diff --name-only main...HEAD
```

Expected changed paths are limited to the plan file, approved specification status, resolver helper, focused tests, service, package files, Nix check wiring, and OpenWRT documentation.

Inspect the diff without printing certificate, JWT, identity, credential, or webhook contents. Verify that no production network command was added.

- [ ] **Step 8: Commit the operator documentation**

Run:

```bash
git add docs/ziti-edge-tunnel-openwrt.md
git commit -S -m "docs(ziti): document OpenWRT r6 resolver"
```

Expected: a signed documentation commit.

- [ ] **Step 9: Request an independent code review**

Read and follow the `requesting-code-review` skill. Dispatch the canonical Pi `reviewer` with fresh context.

Use this review scope:

```text
Task: Review the OpenWRT ziti-edge-tunnel r6 resolver implementation.
Requirements: docs/specs/2026-08-17-ziti-openwrt-r6-resolver-design.md
Plan: docs/plans/2026-08-17-ziti-openwrt-r6-resolver.md
Base: the merge base of main and HEAD
Head: the current HEAD
Focus: recursion boundaries, UCI ownership, secure lock checks, partial commits,
reload rollback, startup ordering, upgrade preservation, final removal, exact IPK
contents, shell portability, and secret safety.
```

Resolve any review finding with the `receiving-code-review` skill. Add a failing test before each behavior fix. Re-run the affected focused check after each fix.

- [ ] **Step 10: Re-run completion verification after review changes**

Run again:

```bash
nix build \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-helper \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-dnsmasq-routing \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ca-bundle \
  .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk \
  .#checks.x86_64-linux.ziti-openwrt-tunnel-script \
  --no-link
nix flake check --accept-flake-config --print-build-logs
git diff --check main...HEAD
git status --short
```

Expected: all checks pass and the worktree is clean.

Do not push. Present the local branch and signed commits for user review. When branch completion is approved, offer a local squash merge into `main` instead of a regular merge.
