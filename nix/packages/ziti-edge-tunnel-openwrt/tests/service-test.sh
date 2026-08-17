#!/usr/bin/env bash
set -euo pipefail

init_script=${1:?usage: service-test.sh /path/to/init-script /path/to/run-managed [shell-command ...]}
wrapper_script=${2:?missing wrapper script path}
shift 2 || true
shells=("$@")
[ "${#shells[@]}" -gt 0 ] || shells=(bash)

busybox_bin=${BUSYBOX:-}
if [ -z "$busybox_bin" ]; then
  busybox_bin=$(command -v busybox || true)
fi

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
  export ZITI_CA_BUNDLE_HELPER="$root/bin/update-ca-bundle"
  export ZITI_DNSMASQ_HELPER="$root/bin/update-dnsmasq"
  export TEST_ENABLED=1
  export TEST_DNS_UPSTREAM=
  export TEST_JWT="$root/etc/openziti/enroll.jwt"
  export TEST_IDENTITY="$root/etc/openziti/identities/router.json"
  export TEST_VERBOSE=3
  export TEST_ENROLL_RESULT=success
  export TEST_RUN_RESULT=64
  export TEST_RUN_COMMAND="$root/run-command"
  export TEST_CA_RESULT=success
  export TEST_CA_COMMAND="$root/ca-command"
  export TEST_DNSMASQ_RESULT=success
  export TEST_DNSMASQ_COMMAND="$root/dnsmasq-command"
  export TEST_START_ORDER="$root/start-order"
  : >"$root/procd-command"
  : >"$TEST_RUN_COMMAND"
  : >"$TEST_CA_COMMAND"
  : >"$TEST_DNSMASQ_COMMAND"
  : >"$TEST_START_ORDER"
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

  cat >"$ZITI_CA_BUNDLE_HELPER" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"$TEST_CA_COMMAND"
printf 'ca\n' >>"$TEST_START_ORDER"
[ "${TEST_CA_RESULT:-failure}" = success ]
MOCK
  chmod 0755 "$ZITI_CA_BUNDLE_HELPER"

  cat >"$ZITI_DNSMASQ_HELPER" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"$TEST_DNSMASQ_COMMAND"
printf 'dnsmasq\n' >>"$TEST_START_ORDER"
[ "${TEST_DNSMASQ_RESULT:-failure}" = success ]
MOCK
  chmod 0755 "$ZITI_DNSMASQ_HELPER"

  config_load() { [ "$1" = ziti-edge-tunnel ]; }
  config_get_bool() { printf -v "$1" '%s' "$TEST_ENABLED"; }
  config_get() {
    case "$3" in
      dns_upstream) printf -v "$1" '%s' "${TEST_DNS_UPSTREAM:-${4-}}" ;;
      jwt) printf -v "$1" '%s' "$TEST_JWT" ;;
      identity) printf -v "$1" '%s' "$TEST_IDENTITY" ;;
      verbose) printf -v "$1" '%s' "$TEST_VERBOSE" ;;
      *) printf -v "$1" '%s' "${4-}" ;;
    esac
  }
  logger() { printf '%s\n' "$*" >>"$root/log"; }
  procd_open_instance() { printf 'procd\n' >>"$TEST_START_ORDER"; }
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

  # Mocks for the shipped supervised wrapper, sourced via ZITI_FUNCTIONS_SH.
  # POSIX-only: the wrapper must also run under BusyBox ash.
  cat >"$root/mocks" <<'WRAPPER'
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
WRAPPER
  export ZITI_FUNCTIONS_SH="$root/mocks"

  $shell_cmd "$wrapper_script" >"$root/wrapper.out" 2>&1 &
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
  assert_contains "$TEST_DNSMASQ_COMMAND" 'ensure'
  [[ ! -s $root/procd-command ]] || fail 'disabled service started a process'
  [[ ! -s $TEST_CA_COMMAND ]] || fail 'disabled service refreshed the CA bundle'
}

case_stop_preserves_dnsmasq() {
  stop_service
  [[ ! -s $TEST_DNSMASQ_COMMAND ]] || fail 'service stop changed dnsmasq rules'
}

case_preparation_precedes_procd() {
  printf '{}\n' >"$TEST_IDENTITY"
  start_service
  assert_contains "$TEST_DNSMASQ_COMMAND" 'ensure'
  assert_contains "$TEST_CA_COMMAND" 'ensure'
  [[ $(sed -n '1p' "$TEST_START_ORDER") = dnsmasq ]] ||
    fail 'dnsmasq preparation did not run first'
  [[ $(sed -n '2p' "$TEST_START_ORDER") = ca ]] ||
    fail 'CA refresh did not run after dnsmasq preparation'
  [[ $(sed -n '3p' "$TEST_START_ORDER") = procd ]] ||
    fail 'procd did not run after preparation'
}

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

case_ca_refresh_failure_blocks_start() {
  printf '{}\n' >"$TEST_IDENTITY"
  export TEST_CA_RESULT=failure
  if start_service; then
    fail 'CA refresh failure started the service'
  fi
  assert_contains "$TEST_CA_COMMAND" 'ensure'
  [[ ! -s $root/procd-command ]] || fail 'CA refresh failure configured procd'
  assert_no_file "$ZITI_RUNTIME_DIR/resolv.conf.before"
}

case_existing_identity() {
  printf '{}\n' >"$TEST_IDENTITY"
  chmod 0644 "$TEST_IDENTITY"
  start_service
  assert_contains "$root/procd-command" '/usr/lib/ziti-edge-tunnel/run-managed'
  if ( run_managed ); then fail 'managed run succeeded'; fi
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
  # start_service validates local material only; enrollment runs in the
  # supervised process so package maintainer scripts never block on it.
  start_service
  assert_contains "$root/procd-command" '/usr/lib/ziti-edge-tunnel/run-managed'
  if ( run_managed ); then fail 'failed enrollment succeeded'; fi
  assert_file "$TEST_JWT"
  assert_no_file "$TEST_IDENTITY"
}

case_successful_enrollment() {
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  start_service
  assert_file "$TEST_JWT"
  assert_no_file "$TEST_IDENTITY"
  assert_contains "$root/procd-command" '/usr/lib/ziti-edge-tunnel/run-managed'
  if ( run_managed ); then fail 'managed run succeeded'; fi
  assert_file "$TEST_IDENTITY"
  assert_no_file "$TEST_JWT"
}

case_existing_identity_preserves_jwt() {
  printf '{}\n' >"$TEST_IDENTITY"
  printf 'unused.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  start_service
  if ( run_managed ); then fail 'managed run succeeded'; fi
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
  assert_contains "$TEST_RUN_COMMAND" '--dns-upstream 127.0.0.1'
  assert_not_contains "$ZITI_RESOLV_CONF" 'nameserver 100.64.0.2'
  assert_contains "$ZITI_RESOLV_CONF" 'nameserver 192.0.2.53'
}

case_configured_dns_upstream() {
  export TEST_DNS_UPSTREAM=192.0.2.54
  printf '{}\n' >"$TEST_IDENTITY"
  if ( run_managed ); then fail 'failed tunnel run succeeded'; fi
  assert_contains "$TEST_RUN_COMMAND" '--dns-upstream 192.0.2.54'
}

case_invalid_dns_upstream_rejected() {
  printf '{}\n' >"$TEST_IDENTITY"
  for invalid in 999.2.3.4 127.0.0 127.0.0.1. 127..0.1 010.000.000.001 resolver; do
    export TEST_DNS_UPSTREAM=$invalid
    : >"$TEST_RUN_COMMAND"
    if ( run_managed ); then fail 'invalid dns_upstream succeeded'; fi
    [[ ! -s $TEST_RUN_COMMAND ]] || fail "invalid dns_upstream launched tunnel: $invalid"
  done
  assert_contains "$root/log" 'dns_upstream must be an IPv4 address'
}

case_identity_symlink_rejected() {
  ln -s "$root/elsewhere.json" "$TEST_IDENTITY"
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  start_service
  if ( run_managed ); then fail 'identity symlink succeeded'; fi
  assert_file "$TEST_JWT"
  assert_no_file "$root/elsewhere.json"
}

case_broad_jwt_rejected() {
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0644 "$TEST_JWT"
  if start_service; then fail 'group/world-readable JWT succeeded'; fi
  assert_file "$TEST_JWT"
  assert_no_file "$TEST_IDENTITY"
  assert_contains "$root/log" 'JWT permissions are too broad'
}

case_unreadable_jwt_rejected() {
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0200 "$TEST_JWT"
  if start_service; then fail 'owner-unreadable JWT succeeded'; fi
  assert_file "$TEST_JWT"
  assert_no_file "$TEST_IDENTITY"
  assert_contains "$root/log" 'JWT is not owner-readable'
}

# Run the enrollment path under BusyBox ash with PATH restricted to
# BusyBox applets minus stat, matching the OpenWRT router userland
# (OpenWRT's BusyBox build has no stat applet).
run_busybox_env_case() (
  set -euo pipefail
  name=$1
  shift
  root="$test_root/$name"
  mkdir -p "$root/bin" "$root/bb" "$root/etc/openziti/identities" "$root/run"

  export ZITI_PROG="$root/bin/ziti-edge-tunnel"
  export ZITI_INIT_SCRIPT="$init_script"
  export ZITI_RUNTIME_DIR="$root/run"
  export ZITI_RESOLV_CONF="$root/resolv.conf"
  export ZITI_CA_BUNDLE_HELPER="$root/bin/update-ca-bundle"
  export ZITI_DNSMASQ_HELPER="$root/bin/update-dnsmasq"
  export TEST_BB_DIR="$root/bb"
  export TEST_PROCD_COMMAND="$root/procd-command"
  export TEST_CA_COMMAND="$root/ca-command"
  export TEST_CA_RESULT=success
  export TEST_DNSMASQ_COMMAND="$root/dnsmasq-command"
  export TEST_DNSMASQ_RESULT=success
  export TEST_START_ORDER="$root/start-order"
  export TEST_ENABLED=1
  export TEST_JWT="$root/etc/openziti/enroll.jwt"
  export TEST_IDENTITY="$root/etc/openziti/identities/router.json"
  export TEST_VERBOSE=3
  : >"$TEST_PROCD_COMMAND"
  : >"$TEST_CA_COMMAND"
  : >"$TEST_DNSMASQ_COMMAND"
  : >"$TEST_START_ORDER"
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
  printf '{"ztAPI":"https://controller.invalid"}\n' >"$identity"
  exit 0
fi
exit 64
MOCK
  chmod 0755 "$ZITI_PROG"

  cat >"$ZITI_CA_BUNDLE_HELPER" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"$TEST_CA_COMMAND"
printf 'ca\n' >>"$TEST_START_ORDER"
[ "${TEST_CA_RESULT:-failure}" = success ]
MOCK
  chmod 0755 "$ZITI_CA_BUNDLE_HELPER"

  cat >"$ZITI_DNSMASQ_HELPER" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"$TEST_DNSMASQ_COMMAND"
printf 'dnsmasq\n' >>"$TEST_START_ORDER"
[ "${TEST_DNSMASQ_RESULT:-failure}" = success ]
MOCK
  chmod 0755 "$ZITI_DNSMASQ_HELPER"

  # BusyBox applet symlinks, deliberately without stat.
  for app in mkdir chmod cp rm awk cat ls sleep kill; do
    ln -s "$busybox_bin" "$root/bb/$app"
  done

  cat >"$root/mocks" <<'WRAPPER'
config_load() { [ "$1" = ziti-edge-tunnel ]; }
config_get_bool() { eval "$1=\"$TEST_ENABLED\""; }
config_get() {
  case "$3" in
    jwt) eval "$1=\"$TEST_JWT\"" ;;
    identity) eval "$1=\"$TEST_IDENTITY\"" ;;
    verbose) eval "$1=\"$TEST_VERBOSE\"" ;;
    *) eval "$1=\"${4-}\"" ;;
  esac
}
logger() { :; }
procd_open_instance() { printf 'procd\n' >>"$TEST_START_ORDER"; }
procd_set_param() {
  if [ "$1" = command ]; then
    shift
    printf '%s\n' "$*" >"$TEST_PROCD_COMMAND"
  fi
}
procd_close_instance() { :; }
procd_add_reload_trigger() { :; }
WRAPPER

  cat >"$root/start-driver" <<'WRAPPER'
PATH=$TEST_BB_DIR
export PATH
. "$TEST_MOCKS"
. "$ZITI_INIT_SCRIPT"
start_service
WRAPPER

  cat >"$root/stop-driver" <<'WRAPPER'
PATH=$TEST_BB_DIR
export PATH
. "$TEST_MOCKS"
. "$ZITI_INIT_SCRIPT"
stop_service
WRAPPER

  "$@"
)

case_busybox_disabled_repairs_dnsmasq() {
  export TEST_ENABLED=0
  export TEST_MOCKS="$root/mocks"
  if ! "$busybox_bin" ash "$root/start-driver"; then
    fail 'disabled start failed under BusyBox'
  fi
  assert_contains "$TEST_DNSMASQ_COMMAND" 'ensure'
  [[ ! -s $TEST_CA_COMMAND ]] || fail 'disabled BusyBox start refreshed CA bundle'
  [[ ! -s $TEST_PROCD_COMMAND ]] || fail 'disabled BusyBox start configured procd'
  [[ $(cat "$TEST_START_ORDER") = dnsmasq ]] ||
    fail 'disabled BusyBox start ran work after dnsmasq preparation'
}

case_busybox_dnsmasq_failure_blocks_start() {
  export TEST_DNSMASQ_RESULT=failure
  export TEST_MOCKS="$root/mocks"
  if "$busybox_bin" ash "$root/start-driver"; then
    fail 'dnsmasq failure started service under BusyBox'
  fi
  assert_contains "$TEST_DNSMASQ_COMMAND" 'ensure'
  [[ ! -s $TEST_CA_COMMAND ]] || fail 'BusyBox CA refresh ran after dnsmasq failure'
  [[ ! -s $TEST_PROCD_COMMAND ]] || fail 'BusyBox dnsmasq failure configured procd'
  [[ $(cat "$TEST_START_ORDER") = dnsmasq ]] ||
    fail 'BusyBox dnsmasq failure ran later preparation'
}

case_busybox_stop_preserves_dnsmasq() {
  export TEST_MOCKS="$root/mocks"
  if ! "$busybox_bin" ash "$root/stop-driver"; then
    fail 'stop_service failed under BusyBox'
  fi
  [[ ! -s $TEST_DNSMASQ_COMMAND ]] || fail 'BusyBox stop changed dnsmasq rules'
}

case_busybox_enrollment_without_stat() {
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  export TEST_MOCKS="$root/mocks"
  if ! "$busybox_bin" ash "$root/start-driver"; then
    fail 'start_service failed under BusyBox without stat'
  fi
  assert_contains "$TEST_PROCD_COMMAND" '/usr/lib/ziti-edge-tunnel/run-managed'
  assert_contains "$TEST_DNSMASQ_COMMAND" 'ensure'
  assert_contains "$TEST_CA_COMMAND" 'ensure'
  [[ $(sed -n '1p' "$TEST_START_ORDER") = dnsmasq ]] ||
    fail 'BusyBox dnsmasq preparation did not run first'
  [[ $(sed -n '2p' "$TEST_START_ORDER") = ca ]] ||
    fail 'BusyBox CA refresh did not run second'
  [[ $(sed -n '3p' "$TEST_START_ORDER") = procd ]] ||
    fail 'BusyBox procd registration did not run last'
  assert_file "$TEST_JWT"
  assert_no_file "$TEST_IDENTITY"
  # The supervised entrypoint performs enrollment under the same userland.
  if PATH="$TEST_BB_DIR" ZITI_FUNCTIONS_SH="$root/mocks" \
    "$busybox_bin" ash "$wrapper_script"; then
    fail 'supervised run succeeded unexpectedly'
  fi
  assert_file "$TEST_IDENTITY"
  assert_no_file "$TEST_JWT"
  [[ $(stat -c %a "$TEST_IDENTITY") = 600 ]] || fail 'identity mode was not corrected'
}

run_case disabled case_disabled
run_case stop-preserves-dnsmasq case_stop_preserves_dnsmasq
run_case preparation-before-procd case_preparation_precedes_procd
run_case dnsmasq-prepare-failure case_dnsmasq_prepare_failure_blocks_start
run_case ca-refresh-failure case_ca_refresh_failure_blocks_start
run_case existing-identity case_existing_identity
run_case missing-material case_missing_material
run_case failed-enrollment case_failed_enrollment
run_case successful-enrollment case_successful_enrollment
run_case existing-identity-jwt case_existing_identity_preserves_jwt
run_case resolver-cleanup case_resolver_cleanup
run_case managed-exit-cleanup case_managed_exit_cleans_resolver
run_case configured-dns-upstream case_configured_dns_upstream
run_case invalid-dns-upstream case_invalid_dns_upstream_rejected
run_case identity-symlink case_identity_symlink_rejected
run_case broad-jwt case_broad_jwt_rejected
run_case unreadable-jwt case_unreadable_jwt_rejected

signal_cases=0
for shell_cmd in "${shells[@]}"; do
  shell_label=${shell_cmd//[^a-zA-Z0-9]/_}
  run_signal_case "sigterm-cleanup-$shell_label" "$shell_cmd" serve 8
  run_signal_case "sigterm-stubborn-$shell_label" "$shell_cmd" stubborn 1
  signal_cases=$((signal_cases + 2))
done

busybox_cases=0
if [ -n "$busybox_bin" ]; then
  run_busybox_env_case busybox-disabled case_busybox_disabled_repairs_dnsmasq
  run_busybox_env_case busybox-dnsmasq-failure case_busybox_dnsmasq_failure_blocks_start
  run_busybox_env_case busybox-stop case_busybox_stop_preserves_dnsmasq
  run_busybox_env_case busybox-enrollment-no-stat case_busybox_enrollment_without_stat
  busybox_cases=4
else
  printf 'skipping busybox environment tests: busybox not found\n'
fi

# The supervised entrypoint must never source rc.common/procd.sh: sourcing
# procd.sh takes the service flock, and a long-lived supervised process
# holding it deadlocks every later init.d action.
case_wrapper_avoids_procd_lock() {
  if grep -E '^[[:space:]]*\.[[:space:]].*(rc\.common|procd\.sh)' "$wrapper_script" >/dev/null; then
    fail 'supervised wrapper sources rc.common/procd.sh'
  fi
  assert_contains "$wrapper_script" '/lib/functions.sh'
  assert_contains "$wrapper_script" 'run_managed'
}
case_wrapper_avoids_procd_lock

printf 'service tests: %s passed\n' "$((17 + signal_cases + busybox_cases + 1))"
