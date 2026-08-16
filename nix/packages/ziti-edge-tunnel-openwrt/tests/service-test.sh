#!/usr/bin/env bash
set -euo pipefail

init_script=${1:?usage: service-test.sh /path/to/init-script [shell-command ...]}
shift || true
shells=("$@")
[ "${#shells[@]}" -gt 0 ] || shells=(bash)

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() { [[ -f $1 ]] || fail "expected file: $1"; }
assert_no_file() { [[ ! -e $1 ]] || fail "expected no file: $1"; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "$1 contains: $2"; }

run_case() (
  set -euo pipefail
  name=$1
  shift
  root="$test_root/$name"
  mkdir -p "$root/bin" "$root/etc/openziti/identities" "$root/run"

  export ZITI_PROG="$root/bin/ziti-edge-tunnel"
  export ZITI_INIT_SCRIPT="$init_script"
  export ZITI_RUNTIME_DIR="$root/run"
  export ZITI_RESOLV_CONF="$root/resolv.conf"
  export TEST_ENABLED=1
  export TEST_JWT="$root/etc/openziti/enroll.jwt"
  export TEST_IDENTITY="$root/etc/openziti/identities/router.json"
  export TEST_VERBOSE=3
  export TEST_ENROLL_RESULT=success
  export TEST_RUN_RESULT=64
  export TEST_RUN_COMMAND="$root/run-command"
  : >"$root/procd-command"
  : >"$TEST_RUN_COMMAND"
  printf 'nameserver 192.0.2.53\n' >"$ZITI_RESOLV_CONF"

  cat >"$ZITI_PROG" <<'MOCK'
#!/bin/sh
set -eu
if [ "$1" = enroll ]; then
  shift
  identity=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --identity) identity=$2; shift 2 ;;
      --jwt) shift 2 ;;
      *) shift ;;
    esac
  done
  [ "${TEST_ENROLL_RESULT:-failure}" = success ] || exit 23
  printf '{"ztAPI":"https://controller.invalid"}\n' >"$identity"
  exit 0
fi
if [ "$1" = run ]; then
  printf '%s\n' "$*" >"$TEST_RUN_COMMAND"
  printf 'nameserver 100.64.0.2\n' >>"$ZITI_RESOLV_CONF"
  exit "${TEST_RUN_RESULT:-64}"
fi
exit 64
MOCK
  chmod 0755 "$ZITI_PROG"

  config_load() { [ "$1" = ziti-edge-tunnel ]; }
  config_get_bool() { printf -v "$1" '%s' "$TEST_ENABLED"; }
  config_get() {
    case "$3" in
      jwt) printf -v "$1" '%s' "$TEST_JWT" ;;
      identity) printf -v "$1" '%s' "$TEST_IDENTITY" ;;
      verbose) printf -v "$1" '%s' "$TEST_VERBOSE" ;;
      *) printf -v "$1" '%s' "${4-}" ;;
    esac
  }
  logger() { printf '%s\n' "$*" >>"$root/log"; }
  procd_open_instance() { :; }
  procd_set_param() {
    if [ "$1" = command ]; then
      shift
      printf '%s\n' "$*" >"$root/procd-command"
    fi
  }
  procd_close_instance() { :; }
  procd_add_reload_trigger() { :; }

  # shellcheck source=/dev/null
  source "$init_script"
  "$@"
)

# Run the init script the way procd does: a single supervised shell process
# running run_managed, with the tunnel as its child. Signals are delivered
# only to the supervised PID, mirroring procd's instance_stop/instance_restart
# (kill(in->proc.pid, SIGTERM); no process-group signal).
run_signal_case() (
  set -euo pipefail
  name=$1
  shell_cmd=$2
  behavior=$3
  stop_timeout=$4
  root="$test_root/$name"
  mkdir -p "$root/bin" "$root/etc/openziti/identities" "$root/run"

  export ZITI_PROG="$root/bin/ziti-edge-tunnel"
  export ZITI_INIT_SCRIPT="$init_script"
  export ZITI_RUNTIME_DIR="$root/run"
  export ZITI_RESOLV_CONF="$root/resolv.conf"
  export ZITI_STOP_TIMEOUT=$stop_timeout
  export TEST_ENABLED=1
  export TEST_IDENTITY="$root/etc/openziti/identities/router.json"
  export TEST_VERBOSE=3
  export TEST_BEHAVIOR=$behavior
  export TEST_RUN_COMMAND="$root/run-command"
  export TEST_PID_FILE="$root/tunnel.pid"
  printf '{}\n' >"$TEST_IDENTITY"
  : >"$TEST_RUN_COMMAND"
  printf 'nameserver 192.0.2.53\n' >"$ZITI_RESOLV_CONF"

  cat >"$ZITI_PROG" <<'MOCK'
#!/bin/sh
set -eu
if [ "$1" = run ]; then
  printf '%s\n' "$*" >"$TEST_RUN_COMMAND"
  printf '%s\n' "$$" >"$TEST_PID_FILE"
  printf 'nameserver 100.64.0.2\n' >>"$ZITI_RESOLV_CONF"
  if [ "${TEST_BEHAVIOR:-serve}" = stubborn ]; then
    trap '' TERM INT
  else
    trap 'exit 143' TERM INT
  fi
  while :; do sleep 1; done
fi
exit 64
MOCK
  chmod 0755 "$ZITI_PROG"

  # POSIX-only mocks: the wrapper must also run under BusyBox ash.
  cat >"$root/wrapper" <<'WRAPPER'
config_load() { [ "$1" = ziti-edge-tunnel ]; }
config_get_bool() { eval "$1=\"$TEST_ENABLED\""; }
config_get() {
  case "$3" in
    identity) eval "$1=\"$TEST_IDENTITY\"" ;;
    verbose) eval "$1=\"$TEST_VERBOSE\"" ;;
    *) eval "$1=\"${4-}\"" ;;
  esac
}
logger() { :; }
procd_open_instance() { :; }
procd_set_param() { :; }
procd_close_instance() { :; }
procd_add_reload_trigger() { :; }
. "$ZITI_INIT_SCRIPT"
run_managed
WRAPPER

  $shell_cmd "$root/wrapper" >"$root/wrapper.out" 2>&1 &
  tracked=$!
  started=0
  for _ in $(seq 1 100); do
    if [ -s "$TEST_PID_FILE" ] && grep -qF 'nameserver 100.64.0.2' "$ZITI_RESOLV_CONF"; then
      started=1
      break
    fi
    sleep 0.05
  done
  [ "$started" -eq 1 ] || fail "[$name] tunnel did not start"
  tunnel_pid=$(cat "$TEST_PID_FILE")

  kill -TERM "$tracked"
  ( sleep 15; kill -KILL "$tracked" 2>/dev/null ) &
  watchdog=$!
  set +e
  wait "$tracked"
  set -e
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  if kill -0 "$tunnel_pid" 2>/dev/null; then
    kill -KILL "$tunnel_pid" 2>/dev/null || true
    fail "[$name] tunnel process survived SIGTERM to the supervised process"
  fi
  assert_not_contains "$ZITI_RESOLV_CONF" 'nameserver 100.64.0.2'
  assert_contains "$ZITI_RESOLV_CONF" 'nameserver 192.0.2.53'
  assert_no_file "$ZITI_RUNTIME_DIR/resolv.conf.before"
)

case_disabled() {
  TEST_ENABLED=0
  start_service
  [[ ! -s $root/procd-command ]] || fail 'disabled service started a process'
}

case_existing_identity() {
  printf '{}\n' >"$TEST_IDENTITY"
  chmod 0644 "$TEST_IDENTITY"
  start_service
  assert_contains "$root/procd-command" "$init_script run_managed"
  [[ $(stat -c %a "$TEST_IDENTITY") = 600 ]] || fail 'identity mode was not corrected'
}

case_missing_material() {
  if start_service; then fail 'missing identity and JWT succeeded'; fi
  [[ ! -s $root/procd-command ]] || fail 'missing material started a process'
}

case_failed_enrollment() {
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  export TEST_ENROLL_RESULT=failure
  if start_service; then fail 'failed enrollment succeeded'; fi
  assert_file "$TEST_JWT"
  assert_no_file "$TEST_IDENTITY"
}

case_successful_enrollment() {
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  start_service
  assert_file "$TEST_IDENTITY"
  assert_no_file "$TEST_JWT"
  assert_contains "$root/procd-command" "$init_script run_managed"
}

case_existing_identity_preserves_jwt() {
  printf '{}\n' >"$TEST_IDENTITY"
  printf 'unused.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  start_service
  assert_file "$TEST_JWT"
  assert_contains "$root/log" 'identity already exists; leaving JWT untouched'
}

case_resolver_cleanup() {
  printf 'nameserver 100.64.0.2\nnameserver 192.0.2.53\nsearch lan\n' >"$ZITI_RESOLV_CONF"
  cleanup_resolver
  assert_not_contains "$ZITI_RESOLV_CONF" 'nameserver 100.64.0.2'
  assert_contains "$ZITI_RESOLV_CONF" 'nameserver 192.0.2.53'
  assert_contains "$ZITI_RESOLV_CONF" 'search lan'
}

case_managed_exit_cleans_resolver() {
  printf '{}\n' >"$TEST_IDENTITY"
  # run_managed now terminates its own process (it is the procd-supervised
  # PID), so invoke it as a child process the way procd does.
  if ( run_managed ); then fail 'failed tunnel run succeeded'; fi
  assert_contains "$TEST_RUN_COMMAND" "run --identity $TEST_IDENTITY"
  assert_contains "$TEST_RUN_COMMAND" '--dns-ip-range 100.64.0.1/10'
  assert_not_contains "$ZITI_RESOLV_CONF" 'nameserver 100.64.0.2'
  assert_contains "$ZITI_RESOLV_CONF" 'nameserver 192.0.2.53'
}

case_identity_symlink_rejected() {
  ln -s "$root/elsewhere.json" "$TEST_IDENTITY"
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  if start_service; then fail 'identity symlink succeeded'; fi
  assert_file "$TEST_JWT"
  assert_no_file "$root/elsewhere.json"
}

run_case disabled case_disabled
run_case existing-identity case_existing_identity
run_case missing-material case_missing_material
run_case failed-enrollment case_failed_enrollment
run_case successful-enrollment case_successful_enrollment
run_case existing-identity-jwt case_existing_identity_preserves_jwt
run_case resolver-cleanup case_resolver_cleanup
run_case managed-exit-cleanup case_managed_exit_cleans_resolver
run_case identity-symlink case_identity_symlink_rejected

signal_cases=0
for shell_cmd in "${shells[@]}"; do
  shell_label=${shell_cmd//[^a-zA-Z0-9]/_}
  run_signal_case "sigterm-cleanup-$shell_label" "$shell_cmd" serve 8
  run_signal_case "sigterm-stubborn-$shell_label" "$shell_cmd" stubborn 1
  signal_cases=$((signal_cases + 2))
done

printf 'service tests: %s passed\n' "$((9 + signal_cases))"
