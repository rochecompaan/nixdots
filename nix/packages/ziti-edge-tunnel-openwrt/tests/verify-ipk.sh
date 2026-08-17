#!/usr/bin/env bash
set -euo pipefail

ipk=${1:?usage: verify-ipk.sh IPK ARCH VERSION RELEASE}
expected_arch=${2:?missing architecture}
expected_version=${3:?missing version}
expected_release=${4:?missing release}
[[ -f $ipk ]] || { printf 'missing ipk: %s\n' "$ipk" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ar t "$ipk" >/dev/null 2>&1; then
  outer_format=ar
  members=$(ar t "$ipk")
elif tar -tf "$ipk" >/dev/null 2>&1; then
  outer_format=tar
  members=$(tar -tf "$ipk")
else
  printf 'unsupported ipk archive: %s\n' "$ipk" >&2
  exit 1
fi

read_member() {
  if [[ $outer_format = ar ]]; then
    ar p "$ipk" "$1"
  else
    tar -xOf "$ipk" "$1"
  fi
}

extract_member() {
  local member=$1 destination=$2 archive=$tmp/${2##*/}.tar
  mkdir -p "$destination"
  case "$member" in
    *.tar.gz) read_member "$member" | gzip -dc >"$archive" ;;
    *.tar.xz) read_member "$member" | xz -dc >"$archive" ;;
    *.tar.zst) read_member "$member" | zstd -dc >"$archive" ;;
    *) printf 'unsupported ipk member: %s\n' "$member" >&2; exit 1 ;;
  esac

  python3 - "$archive" <<'PY'
from pathlib import Path
import sys
import tarfile

archive = Path(sys.argv[1])
with tarfile.open(archive, mode="r:") as package:
    for entry in package:
        parts = entry.name.split("/")
        if entry.name.startswith("/") or ".." in parts:
            raise SystemExit(f"unsafe package path: {entry.name}")
        if not (entry.isfile() or entry.isdir()):
            raise SystemExit(f"unsafe package member type: {entry.name}")
        if entry.uid != 0 or entry.gid != 0:
            raise SystemExit(
                f"non-root package ownership: {entry.name} {entry.uid}:{entry.gid}"
            )
PY
  tar -xf "$archive" -C "$destination"
}

control_member=$(printf '%s\n' "$members" | grep -E '(^|/)control\.tar\.(gz|xz|zst)$')
data_member=$(printf '%s\n' "$members" | grep -E '(^|/)data\.tar\.(gz|xz|zst)$')
[[ -n $control_member && -n $data_member ]] || { printf 'invalid ipk members\n' >&2; exit 1; }
extract_member "$control_member" "$tmp/control"
extract_member "$data_member" "$tmp/data"

control=$tmp/control/control
postinst=$tmp/control/postinst-pkg
prerm=$tmp/control/prerm-pkg
binary=$tmp/data/usr/bin/ziti-edge-tunnel
init=$tmp/data/etc/init.d/ziti-edge-tunnel
config=$tmp/data/etc/config/ziti-edge-tunnel
ca=$tmp/data/etc/ssl/certs/compaan-ca.crt
helper=$tmp/data/usr/lib/ziti-edge-tunnel/update-ca-bundle
wrapper=$tmp/data/usr/lib/ziti-edge-tunnel/run-managed
identity_dir=$tmp/data/etc/openziti/identities

for path in "$control" "$postinst" "$prerm" "$binary" "$init" "$config" "$ca" "$helper" "$wrapper"; do
  [[ -f $path ]] || { printf 'missing package file: %s\n' "$path" >&2; exit 1; }
done
[[ -d $identity_dir ]] || { printf 'missing identity directory\n' >&2; exit 1; }

grep -Fx "Architecture: $expected_arch" "$control" >/dev/null
grep -Fx "Version: ${expected_version}-r${expected_release}" "$control" >/dev/null

depends=$(
  sed -n 's/^Depends: //p' "$control" | tr ',' '\n' | \
    sed -E 's/^[[:space:]]*//; s/[[:space:]]*\(.*\)$//'
)
has_dependency() {
  printf '%s\n' "$depends" | grep -Fx "$1" >/dev/null
}

for dependency in \
  ca-bundle kmod-tun libatomic1 libjson-c5 libopenssl3 libpcap1 libprotobuf-c \
  libsodium libstdcpp6 libuv1 openssl-util zlib; do
  has_dependency "$dependency" || {
    printf 'missing declared dependency: %s\n' "$dependency" >&2
    exit 1
  }
done

[[ $(stat -c %a "$binary") = 755 ]] || { printf 'binary mode is not 0755\n' >&2; exit 1; }
[[ $(stat -c %a "$init") = 755 ]] || { printf 'init mode is not 0755\n' >&2; exit 1; }
[[ $(stat -c %a "$config") = 600 ]] || { printf 'config mode is not 0600\n' >&2; exit 1; }
[[ $(stat -c %a "$ca") = 644 ]] || { printf 'Compaan CA mode is not 0644\n' >&2; exit 1; }
[[ $(stat -c %a "$helper") = 755 ]] || { printf 'CA helper mode is not 0755\n' >&2; exit 1; }
[[ $(stat -c %a "$wrapper") = 755 ]] || { printf 'managed wrapper mode is not 0755\n' >&2; exit 1; }
[[ $(stat -c %a "$identity_dir") = 700 ]] || { printf 'identity directory mode is not 0700\n' >&2; exit 1; }

file_hash=$(openssl dgst -sha256 "$ca")
[[ ${file_hash##* } = 'f0559a622ea96f65ce96b8e148aa1ceff104ad9852fe0f9dfcb1885815fce127' ]] || {
  printf 'Compaan CA file hash mismatch\n' >&2
  exit 1
}
fingerprint=$(openssl x509 -in "$ca" -noout -fingerprint -sha256)
[[ ${fingerprint#*=} = '63:93:BC:6D:23:7E:19:14:0A:A2:4F:97:55:09:99:7A:D9:97:D5:EF:59:A5:61:18:E7:BF:0D:EA:33:F2:DD:06' ]] || {
  printf 'Compaan CA fingerprint mismatch\n' >&2
  exit 1
}
openssl x509 -in "$ca" -noout -text | \
  grep -A1 -F 'X509v3 Basic Constraints' | grep -F 'CA:TRUE' >/dev/null
openssl verify -CAfile "$ca" "$ca" >/dev/null

lifecycle_log=$tmp/lifecycle.log
lifecycle_helper=$tmp/lifecycle-helper
cat >"$lifecycle_helper" <<'HELPER'
#!/bin/sh
set -eu
printf '%s\n' "$1" >>"$LIFECYCLE_LOG"
[ "${LIFECYCLE_RESULT:-failure}" = success ]
HELPER
chmod 0755 "$lifecycle_helper"

run_lifecycle() {
  local script=$1 action=$2
  : >"$lifecycle_log"
  IPKG_INSTROOT= \
  LIFECYCLE_LOG="$lifecycle_log" \
  LIFECYCLE_RESULT=success \
  ZITI_CA_BUNDLE_HELPER="$lifecycle_helper" \
    sh "$script"
  grep -Fx "$action" "$lifecycle_log" >/dev/null || {
    printf '%s did not request CA action: %s\n' "${script##*/}" "$action" >&2
    exit 1
  }
}

run_lifecycle "$postinst" ensure
run_lifecycle "$prerm" remove

for script in "$postinst" "$prerm"; do
  : >"$lifecycle_log"
  IPKG_INSTROOT="$tmp/offline-root" \
  LIFECYCLE_LOG="$lifecycle_log" \
  LIFECYCLE_RESULT=success \
  ZITI_CA_BUNDLE_HELPER="$lifecycle_helper" \
    sh "$script"
  [[ ! -s $lifecycle_log ]] || {
    printf '%s changed host trust during offline install\n' "${script##*/}" >&2
    exit 1
  }
done

: >"$lifecycle_log"
if IPKG_INSTROOT= \
  LIFECYCLE_LOG="$lifecycle_log" \
  LIFECYCLE_RESULT=failure \
  ZITI_CA_BUNDLE_HELPER="$lifecycle_helper" \
    sh "$postinst"; then
  printf 'postinst ignored CA helper failure\n' >&2
  exit 1
fi

secret_file=$(find "$tmp/data/etc/openziti" -mindepth 1 ! -type d -print -quit)
[[ -z $secret_file ]] || { printf 'unexpected OpenZiti material: %s\n' "$secret_file" >&2; exit 1; }

file "$binary" | grep -E 'ELF 32-bit LSB.*MIPS' >/dev/null
readelf -h "$binary" | grep -E 'Data:.*little endian' >/dev/null
readelf -h "$binary" | grep -E 'Machine:.*MIPS' >/dev/null
readelf -l "$binary" | grep -E 'Requesting program interpreter: /lib/ld-musl-mipsel[^]]*\.so\.1' >/dev/null

while read -r soname; do
  case "$soname" in
    libc.so|libgcc_s.so.1|libm.so*|libpthread.so*|librt.so*|libdl.so*) : ;;
    libatomic.so.1) has_dependency libatomic1 ;;
    libjson-c.so.5) has_dependency libjson-c5 ;;
    libssl.so.3|libcrypto.so.3) has_dependency libopenssl3 ;;
    libpcap.so*) has_dependency libpcap1 ;;
    libprotobuf-c.so*) has_dependency libprotobuf-c ;;
    libsodium.so*) has_dependency libsodium ;;
    libstdc++.so.6) has_dependency libstdcpp6 ;;
    libuv.so.1) has_dependency libuv1 ;;
    libz.so.1) has_dependency zlib ;;
    *) printf 'unmapped DT_NEEDED library: %s\n' "$soname" >&2; exit 1 ;;
  esac
 done < <(readelf -d "$binary" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')

printf 'verified %s: %s %s-r%s MIPS little-endian musl\n' \
  "$ipk" "$expected_arch" "$expected_version" "$expected_release"
