#!/usr/bin/env bash
set -euo pipefail

helper=${1:?usage: ca-bundle-test.sh HELPER CA [SHELL ...]}
ca=${2:?missing CA certificate}
shift 2
shells=("$@")
[ "${#shells[@]}" -gt 0 ] || shells=(bash)

begin='# BEGIN ziti-edge-tunnel managed compaan-ca'
end='# END ziti-edge-tunnel managed compaan-ca'

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_count() {
  local expected=$1 pattern=$2 file=$3
  local actual
  actual=$(grep -cF -- "$pattern" "$file" || true)
  [[ $actual = "$expected" ]] || fail "$file has $actual copies of $pattern"
}

assert_fails_unchanged() {
  local shell_cmd=$1 root=$2 action=$3 message=$4
  cp "$root/ca-certificates.crt" "$root/bundle.before"
  if run_helper "$shell_cmd" "$root" "$action" >/dev/null 2>&1; then
    fail "$message"
  fi
  cmp -s "$root/bundle.before" "$root/ca-certificates.crt" ||
    fail "$message changed the CA bundle"
}

run_helper() {
  local shell_cmd=$1 root=$2 action=$3
  local -a shell_words
  read -r -a shell_words <<<"$shell_cmd"
  ZITI_CA_SOURCE="$root/compaan-ca.crt" \
  ZITI_CA_BUNDLE="$root/ca-certificates.crt" \
  ZITI_CA_LOCK="$root/update.lock" \
  ZITI_CA_LOCK_OWNER="${TEST_CA_LOCK_OWNER:-$(id -u)}" \
    "${shell_words[@]}" "$helper" "$action"
}

new_fixture() {
  local root=$1
  mkdir -p "$root"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -subj '/CN=stock-test-ca' -days 1 \
    -keyout "$root/stock.key" -out "$root/stock.crt" >/dev/null 2>&1
  cp "$root/stock.crt" "$root/ca-certificates.crt"
  cp "$ca" "$root/compaan-ca.crt"
  chmod 0640 "$root/ca-certificates.crt"
}

[[ -x $helper ]] || fail "expected executable helper: $helper"

case_count=0
for shell_cmd in "${shells[@]}"; do
  shell_label=${shell_cmd//[^a-zA-Z0-9]/_}
  root="$test_root/$shell_label"
  new_fixture "$root"

  run_helper "$shell_cmd" "$root" ensure
  assert_count 1 "$begin" "$root/ca-certificates.crt"
  assert_count 1 "$end" "$root/ca-certificates.crt"
  [[ $(sed -n '1p' "$root/ca-certificates.crt") = "$begin" ]] ||
    fail 'managed CA block is not first in the bundle'
  [[ $(stat -c %a "$root/ca-certificates.crt") = 640 ]] ||
    fail 'ensure did not preserve bundle mode'
  openssl verify -CAfile "$root/ca-certificates.crt" \
    "$root/compaan-ca.crt" >/dev/null
  case_count=$((case_count + 1))

  cp "$root/ca-certificates.crt" "$root/ensured.once"
  run_helper "$shell_cmd" "$root" ensure
  cmp -s "$root/ensured.once" "$root/ca-certificates.crt" ||
    fail 'repeated ensure changed the managed bundle'
  assert_count 1 "$begin" "$root/ca-certificates.crt"
  assert_count 1 "$end" "$root/ca-certificates.crt"
  case_count=$((case_count + 1))

  cp "$root/stock.crt" "$root/ca-certificates.crt"
  chmod 0640 "$root/ca-certificates.crt"
  run_helper "$shell_cmd" "$root" ensure
  assert_count 1 "$begin" "$root/ca-certificates.crt"
  openssl verify -CAfile "$root/ca-certificates.crt" \
    "$root/compaan-ca.crt" >/dev/null
  case_count=$((case_count + 1))

  run_helper "$shell_cmd" "$root" remove
  cmp -s "$root/stock.crt" "$root/ca-certificates.crt" ||
    fail 'remove did not restore the stock bundle'
  [[ $(stat -c %a "$root/ca-certificates.crt") = 640 ]] ||
    fail 'remove did not preserve bundle mode'
  case_count=$((case_count + 1))

  cp "$root/stock.crt" "$root/ca-certificates.crt"
  printf '%s\n' "$begin" >>"$root/ca-certificates.crt"
  assert_fails_unchanged "$shell_cmd" "$root" ensure \
    'ensure accepted an unmatched begin marker'
  case_count=$((case_count + 1))

  cp "$root/stock.crt" "$root/ca-certificates.crt"
  rm -f "$root/compaan-ca.crt"
  assert_fails_unchanged "$shell_cmd" "$root" ensure \
    'ensure accepted a missing CA source'
  case_count=$((case_count + 1))

  printf 'invalid certificate\n' >"$root/compaan-ca.crt"
  assert_fails_unchanged "$shell_cmd" "$root" ensure \
    'ensure accepted invalid PEM data'
  case_count=$((case_count + 1))

  cp "$root/stock.crt" "$root/compaan-ca.crt"
  assert_fails_unchanged "$shell_cmd" "$root" ensure \
    'ensure accepted a substituted valid CA'
  case_count=$((case_count + 1))

  cat "$ca" "$root/stock.crt" >"$root/compaan-ca.crt"
  assert_fails_unchanged "$shell_cmd" "$root" ensure \
    'ensure accepted an appended CA certificate'
  case_count=$((case_count + 1))

  cp "$ca" "$root/compaan-ca.crt"
  cp "$root/stock.crt" "$root/ca-certificates.crt"
  printf 'do not truncate\n' >"$root/lock-victim"
  cp "$root/lock-victim" "$root/lock-victim.before"
  rm -f "$root/update.lock"
  ln -s "$root/lock-victim" "$root/update.lock"
  if run_helper "$shell_cmd" "$root" ensure >/dev/null 2>&1; then
    fail 'ensure accepted a symbolic-link lock'
  fi
  cmp -s "$root/lock-victim.before" "$root/lock-victim" ||
    fail 'symbolic-link lock changed its target'
  assert_count 0 "$begin" "$root/ca-certificates.crt"
  rm -f "$root/update.lock"
  case_count=$((case_count + 1))

  : >"$root/update.lock"
  chmod 0600 "$root/update.lock"
  export TEST_CA_LOCK_OWNER=99999
  lock_error=$(run_helper "$shell_cmd" "$root" ensure 2>&1) &&
    fail 'ensure accepted a lock with the wrong owner'
  grep -F 'CA bundle lock has the wrong owner' <<<"$lock_error" >/dev/null ||
    fail 'wrong-owner lock returned the wrong error'
  unset TEST_CA_LOCK_OWNER
  rm -f "$root/update.lock"
  case_count=$((case_count + 1))

  : >"$root/update.lock"
  chmod 0644 "$root/update.lock"
  lock_error=$(run_helper "$shell_cmd" "$root" ensure 2>&1) &&
    fail 'ensure accepted a lock with mode 0644'
  grep -F 'CA bundle lock mode is not 0600' <<<"$lock_error" >/dev/null ||
    fail 'wrong-mode lock returned the wrong error'
  rm -f "$root/update.lock"
  case_count=$((case_count + 1))

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
  kill -0 "$helper_pid" 2>/dev/null || fail 'helper did not wait for the CA lock'
  wait "$lock_holder"
  wait "$helper_pid"
  assert_count 1 "$begin" "$root/ca-certificates.crt"
  case_count=$((case_count + 1))

  rm -f "$root/compaan-ca.crt"
  run_helper "$shell_cmd" "$root" remove
  cmp -s "$root/stock.crt" "$root/ca-certificates.crt" ||
    fail 'remove required the CA source certificate'
  case_count=$((case_count + 1))
done

printf 'CA bundle tests: %s passed for %s shell(s)\n' \
  "$case_count" "${#shells[@]}"
