#!/usr/bin/env bash
set -euo pipefail

ipk=${1:?usage: validator-test.sh IPK VALIDATOR}
validator=${2:?missing validator}
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

run_case() {
  local name=$1 mutator=$2
  local root=$test_root/$name
  mkdir -p "$root/outer" "$root/data"
  tar -xzf "$ipk" -C "$root/outer"
  tar -xzf "$root/outer/data.tar.gz" -C "$root/data"
  "$mutator" "$root/data"
  tar -czf "$root/outer/data.tar.gz" -C "$root/data" .
  tar -czf "$root/mutated.ipk" -C "$root/outer" \
    ./debian-binary ./control.tar.gz ./data.tar.gz

  if bash "$validator" "$root/mutated.ipk" mipsel_24kc 1.15.1; then
    fail "validator accepted $name mutation"
  fi
}

run_case embedded-jwt mutate_embedded_jwt
run_case binary-mode mutate_binary_mode
run_case symlink-payload mutate_symlink_payload
printf 'validator tests: 3 passed\n'
