#!/usr/bin/env bash
set -euo pipefail

helper=${1:?usage: update-dnsmasq-test.sh HELPER [SHELL ...]}
shift
shells=("$@")
[ "${#shells[@]}" -gt 0 ] || shells=(bash)

guard=/compaan/
forward=/ha.compaan/100.64.0.2
guard_flag=dnsmasq_compaan_guard_owned
forward_flag=dnsmasq_ha_forward_owned

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_empty() {
  [[ ! -s $1 ]] || fail "expected empty file: $1"
}

assert_log_count() {
  local expected=$1 pattern=$2 file=$3 actual
  actual=$(grep -cF -- "$pattern" "$file" 2>/dev/null || true)
  [[ $actual = "$expected" ]] ||
    fail "$file has $actual copies of $pattern, expected $expected"
}

mock_uci=$test_root/mock-uci.py
printf '#!%s\n' "$(command -v python3)" >"$mock_uci"
cat >>"$mock_uci" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["MOCK_UCI_ROOT"])
log = Path(os.environ["MOCK_UCI_LOG"])
args = sys.argv[1:]
if args and args[0] == "-q":
    args = args[1:]
if not args:
    raise SystemExit(2)

command_text = " ".join(args)
with log.open("a") as stream:
    stream.write(command_text + "\n")

always = os.environ.get("MOCK_UCI_FAIL_ALWAYS", "")
once = os.environ.get("MOCK_UCI_FAIL_ONCE", "")
nth = os.environ.get("MOCK_UCI_FAIL_ON_NTH", "")
if command_text == always:
    raise SystemExit(70)
if command_text == once:
    marker = root / ("failed-" + hashlib.sha256(command_text.encode()).hexdigest())
    if not marker.exists():
        marker.touch()
        raise SystemExit(70)
if ":" in nth:
    wanted_count, wanted_command = nth.split(":", 1)
    if wanted_count.isdigit() and command_text == wanted_command:
        counter_path = root / ("count-" + hashlib.sha256(command_text.encode()).hexdigest())
        count = int(counter_path.read_text()) + 1 if counter_path.exists() else 1
        counter_path.write_text(str(count))
        if count == int(wanted_count):
            raise SystemExit(70)

command = args[0]
operand = args[1] if len(args) > 1 else ""

def package_for_key(key: str) -> str:
    return key.split(".", 1)[0]

def committed_path(package: str) -> Path:
    return root / f"committed-{package}.json"

def staged_path(package: str) -> Path:
    return root / f"staged-{package}.json"

def load(package: str, staged: bool = True):
    path = staged_path(package) if staged and staged_path(package).exists() else committed_path(package)
    if not path.exists():
        return {}
    return json.loads(path.read_text())

def save_staged(package: str, state) -> None:
    staged_path(package).write_text(json.dumps(state, sort_keys=True))

if command == "get":
    package = package_for_key(operand)
    state = load(package)
    if operand not in state:
        raise SystemExit(1)
    value = state[operand]
    if isinstance(value, list):
        print(" ".join(value))
    else:
        print(value)
    raise SystemExit(0)

if command == "show":
    package = package_for_key(operand)
    state = load(package)
    if operand not in state:
        raise SystemExit(1)
    print(f"{operand}={state[operand]}")
    prefix = operand + "."
    for key in sorted(key for key in state if key.startswith(prefix)):
        value = state[key]
        if isinstance(value, list):
            quoted = " ".join(repr(item) for item in value)
            print(f"{key}={quoted}")
        else:
            print(f"{key}={value!r}")
    raise SystemExit(0)

if command in {"set", "add_list", "del_list"}:
    if "=" not in operand:
        raise SystemExit(2)
    key, value = operand.split("=", 1)
    package = package_for_key(key)
    state = load(package)
    if command == "set":
        state[key] = value
    elif command == "add_list":
        current = state.get(key, [])
        if not isinstance(current, list):
            raise SystemExit(2)
        current.append(value)
        state[key] = current
    else:
        current = state.get(key, [])
        if not isinstance(current, list):
            raise SystemExit(2)
        state[key] = [item for item in current if item != value]
    save_staged(package, state)
    raise SystemExit(0)

if command == "commit":
    package = operand
    stage = staged_path(package)
    if stage.exists():
        stage.replace(committed_path(package))
    raise SystemExit(0)

if command == "revert":
    package = operand
    staged_path(package).unlink(missing_ok=True)
    raise SystemExit(0)

raise SystemExit(2)
PY
chmod 0755 "$mock_uci"

write_package() {
  local root=$1 package=$2 json=$3
  printf '%s\n' "$json" >"$root/uci/committed-$package.json"
  rm -f "$root/uci/staged-$package.json"
}

new_fixture() {
  local root=$1
  mkdir -p "$root/bin" "$root/uci"
  : >"$root/uci.log"
  : >"$root/dnsmasq.log"
  write_package "$root" dhcp \
    '{"dhcp.@dnsmasq[0]":"dnsmasq","dhcp.@dnsmasq[0].server":[]}'
  write_package "$root" ziti-edge-tunnel \
    '{"ziti-edge-tunnel.main":"ziti"}'
  ln -s "$mock_uci" "$root/bin/uci"
  cat >"$root/bin/dnsmasq" <<'MOCK'
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
MOCK
  chmod 0755 "$root/bin/dnsmasq"
}

state_update() {
  local root=$1 package=$2 code=$3
  python3 - "$root/uci/committed-$package.json" "$code" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
state = json.loads(path.read_text()) if path.exists() else {}
exec(sys.argv[2], {}, {"state": state})
path.write_text(json.dumps(state, sort_keys=True))
PY
}

set_servers() {
  local root=$1
  shift
  local json
  json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")
  state_update "$root" dhcp "state['dhcp.@dnsmasq[0].server']=$json"
}

set_flag() {
  local root=$1 flag=$2 value=$3
  state_update "$root" ziti-edge-tunnel \
    "state['ziti-edge-tunnel.main.$flag']='$value'"
}

remove_key() {
  local root=$1 package=$2 key=$3
  state_update "$root" "$package" "state.pop('$key', None)"
}

get_servers() {
  local root=$1
  python3 - "$root/uci/committed-dhcp.json" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
for value in state.get("dhcp.@dnsmasq[0].server", []):
    print(value)
PY
}

get_flag() {
  local root=$1 flag=$2
  python3 - "$root/uci/committed-ziti-edge-tunnel.json" "$flag" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
print(state.get("ziti-edge-tunnel.main." + sys.argv[2], "<missing>"))
PY
}

assert_servers() {
  local root=$1
  shift
  local actual expected
  actual=$(get_servers "$root" | sort)
  expected=$(printf '%s\n' "$@" | sed '/^$/d' | sort)
  [[ $actual = "$expected" ]] ||
    fail "unexpected servers in $root: [$actual], expected [$expected]"
}

assert_flag() {
  local root=$1 flag=$2 expected=$3 actual
  actual=$(get_flag "$root" "$flag")
  [[ $actual = "$expected" ]] ||
    fail "$flag is $actual in $root, expected $expected"
}

assert_no_staged_package() {
  local root=$1 package=$2
  [[ ! -e $root/uci/staged-$package.json ]] ||
    fail "staged UCI state remains for $package in $root"
}

run_helper() {
  local shell_cmd=$1 root=$2 action=$3
  local -a shell_words
  read -r -a shell_words <<<"$shell_cmd"
  env \
    PATH="${TEST_PATH_PREFIX:-}$PATH" \
    MOCK_UCI_ROOT="$root/uci" \
    MOCK_UCI_LOG="$root/uci.log" \
    MOCK_UCI_FAIL_ALWAYS="${MOCK_UCI_FAIL_ALWAYS:-}" \
    MOCK_UCI_FAIL_ONCE="${MOCK_UCI_FAIL_ONCE:-}" \
    MOCK_UCI_FAIL_ON_NTH="${MOCK_UCI_FAIL_ON_NTH:-}" \
    MOCK_DNSMASQ_LOG="$root/dnsmasq.log" \
    MOCK_DNSMASQ_ROOT="$root" \
    MOCK_DNSMASQ_RELOAD_RESULT="${MOCK_DNSMASQ_RELOAD_RESULT:-success}" \
    MOCK_DNSMASQ_RELOAD_FAIL_ONCE="${MOCK_DNSMASQ_RELOAD_FAIL_ONCE:-0}" \
    ZITI_DNSMASQ_UCI="$root/bin/uci" \
    ZITI_DNSMASQ_INIT="$root/bin/dnsmasq" \
    ZITI_DNSMASQ_LOCK="$root/update.lock" \
    ZITI_DNSMASQ_LOCK_OWNER="${TEST_DNSMASQ_LOCK_OWNER:-$(id -u)}" \
    "${shell_words[@]}" "$helper" "$action"
}

expect_failure() {
  local shell_cmd=$1 root=$2 action=$3 message=$4
  if run_helper "$shell_cmd" "$root" "$action" >"$root/error.out" 2>&1; then
    fail "$message"
  fi
}

case_add_and_idempotent() {
  local shell_cmd=$1 root=$2
  run_helper "$shell_cmd" "$root" ensure || fail 'ensure did not add missing rules'
  assert_servers "$root" "$guard" "$forward"
  assert_flag "$root" "$guard_flag" 1
  assert_flag "$root" "$forward_flag" 1
  assert_log_count 1 reload "$root/dnsmasq.log"
  assert_log_count 1 'commit dhcp' "$root/uci.log"
  assert_log_count 1 'commit ziti-edge-tunnel' "$root/uci.log"
  run_helper "$shell_cmd" "$root" ensure
  assert_servers "$root" "$guard" "$forward"
  assert_log_count 1 reload "$root/dnsmasq.log"
  assert_log_count 1 'commit dhcp' "$root/uci.log"
  assert_log_count 1 'commit ziti-edge-tunnel' "$root/uci.log"
}

case_external_both() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard" "$forward"
  run_helper "$shell_cmd" "$root" ensure
  assert_servers "$root" "$guard" "$forward"
  assert_flag "$root" "$guard_flag" '<missing>'
  assert_flag "$root" "$forward_flag" '<missing>'
  assert_empty "$root/dnsmasq.log"
}

case_external_guard() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard"
  run_helper "$shell_cmd" "$root" ensure
  assert_servers "$root" "$guard" "$forward"
  assert_flag "$root" "$guard_flag" '<missing>'
  assert_flag "$root" "$forward_flag" 1
  assert_log_count 1 reload "$root/dnsmasq.log"
}

case_external_forward() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$forward"
  run_helper "$shell_cmd" "$root" ensure
  assert_servers "$root" "$guard" "$forward"
  assert_flag "$root" "$guard_flag" 1
  assert_flag "$root" "$forward_flag" '<missing>'
  assert_log_count 1 reload "$root/dnsmasq.log"
}

case_restore_guard() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$forward"
  set_flag "$root" "$guard_flag" 1
  set_flag "$root" "$forward_flag" 1
  run_helper "$shell_cmd" "$root" ensure
  assert_servers "$root" "$guard" "$forward"
  assert_log_count 1 reload "$root/dnsmasq.log"
}

case_restore_forward() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard"
  set_flag "$root" "$guard_flag" 1
  set_flag "$root" "$forward_flag" 1
  run_helper "$shell_cmd" "$root" ensure
  assert_servers "$root" "$guard" "$forward"
  assert_log_count 1 reload "$root/dnsmasq.log"
}

case_remove_owned() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard" "$forward"
  set_flag "$root" "$guard_flag" 1
  set_flag "$root" "$forward_flag" 1
  run_helper "$shell_cmd" "$root" remove
  assert_servers "$root"
  assert_flag "$root" "$guard_flag" 0
  assert_flag "$root" "$forward_flag" 0
  assert_log_count 1 reload "$root/dnsmasq.log"
}

case_remove_mixed() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard" "$forward"
  set_flag "$root" "$guard_flag" 0
  set_flag "$root" "$forward_flag" 1
  run_helper "$shell_cmd" "$root" remove
  assert_servers "$root" "$guard"
  assert_flag "$root" "$guard_flag" 0
  assert_flag "$root" "$forward_flag" 0
  assert_log_count 1 reload "$root/dnsmasq.log"
}

case_remove_stale_owner() {
  local shell_cmd=$1 root=$2
  set_flag "$root" "$guard_flag" 1
  set_flag "$root" "$forward_flag" 1
  run_helper "$shell_cmd" "$root" remove
  assert_servers "$root"
  assert_flag "$root" "$guard_flag" 0
  assert_flag "$root" "$forward_flag" 0
  assert_empty "$root/dnsmasq.log"
}

case_unchanged_remove() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard" "$forward"
  run_helper "$shell_cmd" "$root" remove
  assert_servers "$root" "$guard" "$forward"
  assert_empty "$root/dnsmasq.log"
}

case_invalid_flag() {
  local shell_cmd=$1 root=$2
  set_flag "$root" "$guard_flag" yes
  expect_failure "$shell_cmd" "$root" ensure 'invalid flag was accepted'
  assert_servers "$root"
  assert_empty "$root/dnsmasq.log"
}

case_missing_dnsmasq_section() {
  local shell_cmd=$1 root=$2
  remove_key "$root" dhcp 'dhcp.@dnsmasq[0]'
  expect_failure "$shell_cmd" "$root" ensure 'missing dnsmasq section was accepted'
  assert_empty "$root/dnsmasq.log"
}

case_missing_ziti_section() {
  local shell_cmd=$1 root=$2
  remove_key "$root" ziti-edge-tunnel 'ziti-edge-tunnel.main'
  expect_failure "$shell_cmd" "$root" ensure 'missing ziti section was accepted'
  assert_servers "$root"
  assert_empty "$root/dnsmasq.log"
}

case_uci_read_error() {
  local shell_cmd=$1 root=$2
  export MOCK_UCI_FAIL_ALWAYS='get dhcp.@dnsmasq[0]'
  expect_failure "$shell_cmd" "$root" ensure 'UCI read error was ignored'
  unset MOCK_UCI_FAIL_ALWAYS
  assert_servers "$root"
  assert_empty "$root/dnsmasq.log"
}

case_server_list_read_error() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard"
  export MOCK_UCI_FAIL_ALWAYS='get dhcp.@dnsmasq[0].server'
  expect_failure "$shell_cmd" "$root" ensure 'server-list read error was ignored'
  unset MOCK_UCI_FAIL_ALWAYS
  assert_servers "$root" "$guard"
  assert_flag "$root" "$guard_flag" '<missing>'
  assert_flag "$root" "$forward_flag" '<missing>'
  assert_empty "$root/dnsmasq.log"
}

case_guard_flag_read_error() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard" "$forward"
  set_flag "$root" "$guard_flag" 0
  export MOCK_UCI_FAIL_ALWAYS="get ziti-edge-tunnel.main.$guard_flag"
  expect_failure "$shell_cmd" "$root" ensure 'guard ownership read error was ignored'
  unset MOCK_UCI_FAIL_ALWAYS
  assert_servers "$root" "$guard" "$forward"
  assert_flag "$root" "$guard_flag" 0
  assert_empty "$root/dnsmasq.log"
}

case_forward_flag_read_error() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard" "$forward"
  set_flag "$root" "$forward_flag" 0
  export MOCK_UCI_FAIL_ALWAYS="get ziti-edge-tunnel.main.$forward_flag"
  expect_failure "$shell_cmd" "$root" ensure 'forward ownership read error was ignored'
  unset MOCK_UCI_FAIL_ALWAYS
  assert_servers "$root" "$guard" "$forward"
  assert_flag "$root" "$forward_flag" 0
  assert_empty "$root/dnsmasq.log"
}

case_uci_write_error() {
  local shell_cmd=$1 root=$2
  export MOCK_UCI_FAIL_ALWAYS="add_list dhcp.@dnsmasq[0].server=$guard"
  expect_failure "$shell_cmd" "$root" ensure 'UCI write error was ignored'
  unset MOCK_UCI_FAIL_ALWAYS
  assert_servers "$root"
  assert_flag "$root" "$guard_flag" 1
  assert_flag "$root" "$forward_flag" 1
  assert_empty "$root/dnsmasq.log"
}

case_ownership_commit_error() {
  local shell_cmd=$1 root=$2
  export MOCK_UCI_FAIL_ALWAYS='commit ziti-edge-tunnel'
  expect_failure "$shell_cmd" "$root" ensure 'ownership commit error was ignored'
  unset MOCK_UCI_FAIL_ALWAYS
  assert_servers "$root"
  assert_flag "$root" "$guard_flag" '<missing>'
  assert_flag "$root" "$forward_flag" '<missing>'
  assert_empty "$root/dnsmasq.log"
}

case_rule_commit_error() {
  local shell_cmd=$1 root=$2
  export MOCK_UCI_FAIL_ALWAYS='commit dhcp'
  expect_failure "$shell_cmd" "$root" ensure 'rule commit error was ignored'
  unset MOCK_UCI_FAIL_ALWAYS
  assert_servers "$root"
  assert_flag "$root" "$guard_flag" 1
  assert_flag "$root" "$forward_flag" 1
  assert_empty "$root/dnsmasq.log"
}

case_ensure_reload_error() {
  local shell_cmd=$1 root=$2
  export MOCK_DNSMASQ_RELOAD_FAIL_ONCE=1
  expect_failure "$shell_cmd" "$root" ensure 'reload error was ignored during ensure'
  unset MOCK_DNSMASQ_RELOAD_FAIL_ONCE
  assert_servers "$root"
  assert_flag "$root" "$guard_flag" 1
  assert_flag "$root" "$forward_flag" 1
  assert_log_count 2 reload "$root/dnsmasq.log"
}

case_remove_reload_error() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard" "$forward"
  set_flag "$root" "$guard_flag" 1
  set_flag "$root" "$forward_flag" 1
  export MOCK_DNSMASQ_RELOAD_FAIL_ONCE=1
  expect_failure "$shell_cmd" "$root" remove 'reload error was ignored during remove'
  unset MOCK_DNSMASQ_RELOAD_FAIL_ONCE
  assert_servers "$root" "$guard" "$forward"
  assert_flag "$root" "$guard_flag" 1
  assert_flag "$root" "$forward_flag" 1
  assert_log_count 2 reload "$root/dnsmasq.log"
}

case_ensure_rollback_commit_error() {
  local shell_cmd=$1 root=$2
  export MOCK_DNSMASQ_RELOAD_FAIL_ONCE=1
  export MOCK_UCI_FAIL_ON_NTH='2:commit dhcp'
  expect_failure "$shell_cmd" "$root" ensure 'ensure rollback commit error was ignored'
  unset MOCK_DNSMASQ_RELOAD_FAIL_ONCE MOCK_UCI_FAIL_ON_NTH
  assert_servers "$root" "$guard" "$forward"
  assert_flag "$root" "$guard_flag" 1
  assert_flag "$root" "$forward_flag" 1
  assert_no_staged_package "$root" dhcp
  assert_log_count 1 'revert dhcp' "$root/uci.log"
  assert_log_count 1 reload "$root/dnsmasq.log"
}

case_remove_rollback_commit_error() {
  local shell_cmd=$1 root=$2
  set_servers "$root" "$guard" "$forward"
  set_flag "$root" "$guard_flag" 1
  set_flag "$root" "$forward_flag" 1
  export MOCK_DNSMASQ_RELOAD_FAIL_ONCE=1
  export MOCK_UCI_FAIL_ON_NTH='2:commit dhcp'
  expect_failure "$shell_cmd" "$root" remove 'remove rollback commit error was ignored'
  unset MOCK_DNSMASQ_RELOAD_FAIL_ONCE MOCK_UCI_FAIL_ON_NTH
  assert_servers "$root"
  assert_flag "$root" "$guard_flag" 1
  assert_flag "$root" "$forward_flag" 1
  assert_no_staged_package "$root" dhcp
  assert_log_count 1 'revert dhcp' "$root/uci.log"
  assert_log_count 1 reload "$root/dnsmasq.log"
}

case_unknown_action() {
  local shell_cmd=$1 root=$2 status
  set +e
  run_helper "$shell_cmd" "$root" invalid >"$root/error.out" 2>&1
  status=$?
  set -e
  [[ $status = 2 ]] || fail "invalid action exited $status instead of 2"
  assert_empty "$root/uci.log"
  assert_empty "$root/dnsmasq.log"
}

case_lock_symlink() {
  local shell_cmd=$1 root=$2
  ln -s "$root/target" "$root/update.lock"
  expect_failure "$shell_cmd" "$root" ensure 'symbolic-link lock was accepted'
  assert_empty "$root/uci.log"
}

case_lock_directory() {
  local shell_cmd=$1 root=$2
  mkdir "$root/update.lock"
  expect_failure "$shell_cmd" "$root" ensure 'directory lock was accepted'
  assert_empty "$root/uci.log"
}

case_lock_mode() {
  local shell_cmd=$1 root=$2
  : >"$root/update.lock"
  chmod 0644 "$root/update.lock"
  expect_failure "$shell_cmd" "$root" ensure 'mode 0644 lock was accepted'
  assert_empty "$root/uci.log"
}

case_lock_owner() {
  local shell_cmd=$1 root=$2
  (umask 077; : >"$root/update.lock")
  export TEST_DNSMASQ_LOCK_OWNER=99999
  expect_failure "$shell_cmd" "$root" ensure 'wrong-owner lock was accepted'
  unset TEST_DNSMASQ_LOCK_OWNER
  assert_empty "$root/uci.log"
}

case_lock_inode() {
  local shell_cmd=$1 root=$2 real_ls
  real_ls=$(command -v ls)
  mkdir "$root/race-bin"
  cat >"$root/race-bin/ls" <<'MOCK'
#!/bin/sh
set -eu
if [ "$*" = '-idnL /proc/self/fd/9' ]; then
  "$REAL_LS" "$@"
  rm -f "$ZITI_DNSMASQ_LOCK"
  (umask 077; : >"$ZITI_DNSMASQ_LOCK")
  exit 0
fi
exec "$REAL_LS" "$@"
MOCK
  chmod 0755 "$root/race-bin/ls"
  export REAL_LS="$real_ls"
  export TEST_PATH_PREFIX="$root/race-bin:"
  expect_failure "$shell_cmd" "$root" ensure 'lock inode replacement was accepted'
  unset REAL_LS TEST_PATH_PREFIX
  assert_empty "$root/uci.log"
}

case_lock_serialization() {
  local shell_cmd=$1 root=$2 lock_holder helper_pid
  (
    umask 077
    exec 8>"$root/update.lock"
    flock 8
    : >"$root/lock-held"
    sleep 1
  ) &
  lock_holder=$!
  while [[ ! -e $root/lock-held ]]; do sleep 0.02; done
  run_helper "$shell_cmd" "$root" ensure &
  helper_pid=$!
  sleep 0.1
  kill -0 "$helper_pid" 2>/dev/null || fail 'helper did not wait for dnsmasq lock'
  wait "$lock_holder"
  wait "$helper_pid"
  assert_servers "$root" "$guard" "$forward"
  assert_log_count 1 reload "$root/dnsmasq.log"
}

run_case() {
  local shell_cmd=$1 name=$2 case_function=$3
  local shell_label=${shell_cmd//[^a-zA-Z0-9]/_}
  local root="$test_root/$shell_label/$name"
  new_fixture "$root"
  ("$case_function" "$shell_cmd" "$root")
  case_count=$((case_count + 1))
}

[[ -x $helper ]] || fail "expected executable helper: $helper"

case_count=0
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
