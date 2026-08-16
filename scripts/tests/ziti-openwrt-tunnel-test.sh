#!/usr/bin/env bash
set -euo pipefail

script_source=${1:?usage: ziti-openwrt-tunnel-test.sh /path/to/ziti-openwrt-tunnel.sh}
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "$1 contains: $2"; }
assert_no_file() { [[ ! -e $1 ]] || fail "expected no file: $1"; }

run_case() (
  set -euo pipefail
  name=$1
  shift
  root="$test_root/$name"
  mkdir -p "$root/bin" "$root/repo/scripts" "$root/fake-result"

  # Run a copy in a throwaway repo layout so REPO_ROOT side effects
  # (nix result symlink) stay inside the test root.
  cp "$script_source" "$root/repo/scripts/ziti-openwrt-tunnel.sh"
  chmod 0755 "$root/repo/scripts/ziti-openwrt-tunnel.sh"
  # Invoke through bash: /usr/bin/env shebangs do not resolve in the
  # nix build sandbox.
  run_script() { bash "$root/repo/scripts/ziti-openwrt-tunnel.sh" "$@"; }

  export TEST_LOG="$root/log"
  export TEST_SSH_STDIN="$root/ssh-stdin"
  export PATH="$root/bin:$PATH"
  : >"$TEST_LOG"

  cat >"$root/bin/ziti" <<'STUB'
#!/bin/sh
printf 'ziti' >>"$TEST_LOG"
printf ' %s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
if [ "${1-} ${2-}" = "edge list" ] && [ "${3-}" = identities ]; then
  if [ "${4-}" = "limit 1" ]; then
    [ "${TEST_LOGGED_IN:-1}" = 1 ] || { echo 'authentication required' >&2; exit 1; }
    printf '{"data":[{"name":"someone-else"}]}\n'
    exit 0
  fi
  if [ "${TEST_IDENTITY_EXISTS:-0}" = 1 ]; then
    printf '{"data":[{"name":"taken"}]}\n'
  else
    printf '{"data":[]}\n'
  fi
  exit 0
fi
if [ "${1-} ${2-}" = "edge create" ] && [ "${3-}" = identity ]; then
  name=${4-}
  out=
  while [ $# -gt 0 ]; do
    case $1 in
      -o) out=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$out" ] || { echo 'missing -o' >&2; exit 1; }
  printf 'FAKE-JWT-FOR-%s\n' "$name" >"$out"
  exit 0
fi
echo "unexpected ziti call: $*" >&2
exit 1
STUB

  cat >"$root/bin/ssh" <<'STUB'
#!/bin/sh
printf 'ssh' >>"$TEST_LOG"
printf ' %s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
cmd=${2-}
case "$cmd" in
  *'cat > /etc/openziti/enroll.jwt'*)
    [ "${TEST_TRANSFER_OK:-1}" = 1 ] || exit 1
    cat >"$TEST_SSH_STDIN" ;;
esac
case "$cmd" in
  *'identities/router.json'*)
    [ "${TEST_ENROLL_OK:-1}" = 1 ] || exit 1 ;;
  *'/etc/init.d/ziti-edge-tunnel running'*)
    [ "${TEST_RUNNING:-1}" = 1 ] || exit 1 ;;
  'ziti-edge-tunnel version') printf 'v1.15.1\n' ;;
esac
exit 0
STUB

  cat >"$root/bin/scp" <<'STUB'
#!/bin/sh
printf 'scp' >>"$TEST_LOG"
printf ' %s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
exit 0
STUB

  cat >"$root/bin/nix" <<'STUB'
#!/bin/sh
printf 'nix' >>"$TEST_LOG"
printf ' %s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
if [ "${1-}" = build ]; then
  printf 'fake-ipk\n' >"$TEST_FAKE_RESULT/ziti-edge-tunnel_1.15.1-1_mipsel_24kc.ipk"
  ln -sfn "$TEST_FAKE_RESULT" result
fi
exit 0
STUB

  chmod 0755 "$root/bin/"*
  export TEST_FAKE_RESULT="$root/fake-result"

  "$@"
)

assert_no_password_flags() {
  if grep -E 'ziti .* (-p |--password)' "$TEST_LOG" >/dev/null; then
    fail 'password flag passed to ziti'
  fi
}

jwt_output_path() {
  awk '/ziti edge create identity/ { for (i = 1; i <= NF; i++) if ($i == "-o") print $(i + 1) }' "$TEST_LOG"
}

case_usage_error_without_subcommand() {
  if run_script 2>"$root/err"; then fail 'missing subcommand succeeded'; fi
  assert_contains "$root/err" 'Usage:'
}

case_unknown_subcommand() {
  if run_script bogus 2>"$root/err"; then fail 'unknown subcommand succeeded'; fi
  assert_contains "$root/err" 'Usage:'
}

case_enroll_requires_identity() {
  if run_script enroll 2>"$root/err"; then fail 'enroll without --identity succeeded'; fi
  assert_contains "$root/err" '--identity'
}

case_enroll_requires_login() {
  export TEST_LOGGED_IN=0
  if run_script enroll --identity router-ax53u 2>"$root/err"; then
    fail 'enroll without login succeeded'
  fi
  assert_contains "$root/err" 'ziti edge login'
  assert_contains "$root/err" 'ctrl.compaan.cloud'
  assert_no_password_flags
}

case_enroll_refuses_existing_identity() {
  export TEST_IDENTITY_EXISTS=1
  if run_script enroll --identity router-ax53u 2>"$root/err"; then
    fail 'enroll with existing identity succeeded'
  fi
  assert_contains "$root/err" 'already exists'
  assert_contains "$root/err" 'ziti edge delete identity'
  assert_not_contains "$TEST_LOG" 'ziti edge create identity'
  assert_no_password_flags
}

case_enroll_happy_path() {
  run_script enroll --identity router-ax53u --attrs admin
  assert_contains "$TEST_LOG" 'ziti edge create identity router-ax53u -o '
  assert_contains "$TEST_LOG" '--role-attributes admin'
  assert_contains "$TEST_LOG" 'umask 077; cat > /etc/openziti/enroll.jwt'
  assert_contains "$TEST_SSH_STDIN" 'FAKE-JWT-FOR-router-ax53u'
  assert_contains "$TEST_LOG" 'uci set ziti-edge-tunnel.main.enabled'
  assert_contains "$TEST_LOG" '/etc/init.d/ziti-edge-tunnel start'
  jwt_file=$(jwt_output_path)
  [ -n "$jwt_file" ] || fail 'no JWT output path recorded'
  case "$jwt_file" in
    "$root"/repo/*) fail 'JWT written inside the repo' ;;
  esac
  assert_no_file "$jwt_file"
  if find "$root/repo" -name '*.jwt' -print -quit | grep -q .; then
    fail 'JWT left inside the repo'
  fi
  assert_no_password_flags
}

case_enroll_transfer_failure_cleans_jwt() {
  export TEST_TRANSFER_OK=0
  if run_script enroll --identity router-ax53u 2>"$root/err"; then
    fail 'enroll with failed transfer succeeded'
  fi
  jwt_file=$(jwt_output_path)
  [ -n "$jwt_file" ] || fail 'no JWT output path recorded'
  assert_no_file "$jwt_file"
  assert_no_password_flags
}

case_enroll_timeout_reports_logs() {
  export TEST_ENROLL_OK=0
  export ZITI_ENROLL_TIMEOUT=1
  if run_script enroll --identity router-ax53u 2>"$root/err"; then
    fail 'stalled enrollment succeeded'
  fi
  assert_contains "$root/err" 'logread'
  assert_no_password_flags
}

case_install_with_ipk_skips_build() {
  printf 'fake-ipk\n' >"$root/given.ipk"
  run_script install --ipk "$root/given.ipk"
  assert_contains "$TEST_LOG" "scp $root/given.ipk"
  assert_contains "$TEST_LOG" 'opkg update && opkg install /tmp/ziti-edge-tunnel_*.ipk'
  assert_contains "$TEST_LOG" 'ziti-edge-tunnel version'
  assert_not_contains "$TEST_LOG" 'nix build'
}

case_install_builds_ipk() {
  run_script install
  assert_contains "$TEST_LOG" 'nix build'
  assert_contains "$TEST_LOG" 'scp '
  assert_contains "$TEST_LOG" 'result/ziti-edge-tunnel_1.15.1-1_mipsel_24kc.ipk'
  assert_contains "$TEST_LOG" 'opkg install'
}

case_install_rejects_missing_ipk() {
  if run_script install --ipk "$root/nope.ipk" 2>"$root/err"; then
    fail 'install with missing ipk succeeded'
  fi
  assert_contains "$root/err" 'not found'
  assert_not_contains "$TEST_LOG" 'scp '
}

case_update_restarts_running_tunnel() {
  printf 'fake-ipk\n' >"$root/given.ipk"
  export TEST_RUNNING=1
  run_script update --ipk "$root/given.ipk"
  assert_contains "$TEST_LOG" 'opkg install'
  assert_contains "$TEST_LOG" '/etc/init.d/ziti-edge-tunnel restart'
  assert_contains "$TEST_LOG" 'ziti-edge-tunnel version'
}

case_update_leaves_stopped_tunnel_stopped() {
  printf 'fake-ipk\n' >"$root/given.ipk"
  export TEST_RUNNING=0
  run_script update --ipk "$root/given.ipk"
  assert_contains "$TEST_LOG" 'opkg install'
  assert_not_contains "$TEST_LOG" '/etc/init.d/ziti-edge-tunnel restart'
}

run_case usage-error case_usage_error_without_subcommand
run_case unknown-subcommand case_unknown_subcommand
run_case enroll-requires-identity case_enroll_requires_identity
run_case enroll-requires-login case_enroll_requires_login
run_case enroll-refuses-existing case_enroll_refuses_existing_identity
run_case enroll-happy case_enroll_happy_path
run_case enroll-transfer-failure case_enroll_transfer_failure_cleans_jwt
run_case enroll-timeout case_enroll_timeout_reports_logs
run_case install-with-ipk case_install_with_ipk_skips_build
run_case install-builds case_install_builds_ipk
run_case install-missing-ipk case_install_rejects_missing_ipk
run_case update-restarts case_update_restarts_running_tunnel
run_case update-stopped case_update_leaves_stopped_tunnel_stopped
printf 'operator script tests: 13 passed\n'
