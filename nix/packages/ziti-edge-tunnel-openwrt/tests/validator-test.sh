#!/usr/bin/env bash
set -euo pipefail

ipk=${1:?usage: validator-test.sh IPK VALIDATOR RELEASE}
validator=${2:?missing validator}
expected_release=${3:?missing expected release}
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mutate_embedded_jwt() {
  local data=$1
  printf 'signed.jwt\n' >"$data/etc/openziti/enroll.jwt"
  chmod 0600 "$data/etc/openziti/enroll.jwt"
}

mutate_binary_mode() {
  chmod 0644 "$1/usr/bin/ziti-edge-tunnel"
}

mutate_symlink_payload() {
  ln -s /tmp/escape "$1/usr/bin/unexpected-link"
}

mutate_missing_ca() {
  rm -f "$1/etc/ssl/certs/compaan-ca.crt"
}

mutate_substituted_ca() {
  cp "$substitute_ca" "$1/etc/ssl/certs/compaan-ca.crt"
}

mutate_missing_ca_helper() {
  rm -f "$1/usr/lib/ziti-edge-tunnel/update-ca-bundle"
}

mutate_appended_ca() {
  cat "$substitute_ca" >>"$1/etc/ssl/certs/compaan-ca.crt"
}

mutate_missing_wrapper() {
  rm -f "$1/usr/lib/ziti-edge-tunnel/run-managed"
}

mutate_noop() {
  :
}

run_case() {
  local name=$1 mutator=$2
  local root=$test_root/$name
  mkdir -p "$root/outer" "$root/data"
  tar -xzf "$ipk" -C "$root/outer"
  tar -xzf "$root/outer/data.tar.gz" -C "$root/data"
  "$mutator" "$root/data"
  local owner=0
  [[ $name = nonroot-ownership ]] && owner=1234
  tar --owner="$owner" --group="$owner" \
    -czf "$root/outer/data.tar.gz" -C "$root/data" .
  tar -czf "$root/mutated.ipk" -C "$root/outer" \
    ./debian-binary ./control.tar.gz ./data.tar.gz

  if bash "$validator" "$root/mutated.ipk" mipsel_24kc 1.15.1 "$expected_release"; then
    fail "validator accepted $name mutation"
  fi
}

substitute_ca=$test_root/substitute-ca.crt
openssl req -x509 -newkey rsa:2048 -nodes \
  -subj '/CN=substituted-test-ca' -days 1 \
  -keyout "$test_root/substitute-ca.key" \
  -out "$substitute_ca" >/dev/null 2>&1

run_case embedded-jwt mutate_embedded_jwt
run_case binary-mode mutate_binary_mode
run_case symlink-payload mutate_symlink_payload
run_case missing-ca mutate_missing_ca
run_case substituted-ca mutate_substituted_ca
run_case missing-ca-helper mutate_missing_ca_helper
run_case appended-ca mutate_appended_ca
run_case missing-wrapper mutate_missing_wrapper
run_case nonroot-ownership mutate_noop
printf 'validator tests: 9 passed\n'
