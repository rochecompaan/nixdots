# OpenWRT Compaan CA Trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the Compaan CA in `ziti-edge-tunnel` r5 and trust it for router-originated HTTPS requests.

**Architecture:** A focused POSIX shell helper manages one marked CA block in the stock OpenWRT bundle. Package scripts and the init script call the helper, while focused tests cover bundle mutation, service failure, and IPK contents.

**Tech Stack:** Nix, OpenWRT SDK, POSIX shell, BusyBox ash, OpenSSL, opkg, procd, Bash test harnesses

## Global Constraints

- Work only in `/home/roche/nixdots/.worktrees/ziti-openwrt-compaan-ca` until the local squash merge.
- Keep `modules/nixos/core/certs/compaan-ca.crt` as the only repository copy of the CA.
- Use SHA-256 fingerprint `63:93:BC:6D:23:7E:19:14:0A:A2:4F:97:55:09:99:7A:D9:97:D5:EF:59:A5:61:18:E7:BF:0D:EA:33:F2:DD:06`.
- Build for OpenWRT `24.10.3`, target `ramips/mt7621`, architecture `mipsel_24kc`.
- Keep the application version at `1.15.1` and change the package release from r4 to r5.
- Keep `/usr/lib/ziti-edge-tunnel/run-managed` as the procd command.
- Keep the tunnel limited to router-originated traffic.
- Keep `--dns-upstream 127.0.0.1` as the default runtime argument.
- Use `/tmp/lock/ziti-edge-tunnel-ca.lock` for CA bundle changes.
- Do not use the procd service lock for CA bundle changes.
- Do not manage `/etc/hosts` in the package.
- Do not change either Traefik instance or the Home Assistant ingress.
- Do not print certificate contents, identity contents, JWTs, or the production webhook path.
- Do not call init-script stop or restart while the procd service lock is held.
- Use automated tests for helper logic, service behavior, package lifecycle contracts, and regressions.
- Use direct validation for certificate metadata, package versions, permissions, and documentation.
- Sign every commit. Do not bypass hooks or commit signing.
- Do not push.
- Preserve unrelated commits and worktrees.
- Do not create Intervals timers or entries for this repository.

---

### Task 1: Implement the CA bundle helper with TDD

**Files:**
- Create: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-ca-bundle`
- Create: `nix/packages/ziti-edge-tunnel-openwrt/tests/ca-bundle-test.sh`
- Modify: `modules/packages/ziti-edge-tunnel-openwrt.nix:5-60`

**Interfaces:**
- Consumes: `modules/nixos/core/certs/compaan-ca.crt`
- Produces: `update-ca-bundle ensure|remove`
- Produces: `ZITI_CA_SOURCE`, `ZITI_CA_BUNDLE`, and `ZITI_CA_LOCK` test overrides
- Produces: `checks.x86_64-linux.ziti-edge-tunnel-openwrt-ca-bundle`

- [ ] **Step 1: Write the failing helper test**

Create `ca-bundle-test.sh` with this command interface:

```bash
#!/usr/bin/env bash
set -euo pipefail

helper=${1:?usage: ca-bundle-test.sh HELPER CA [SHELL ...]}
ca=${2:?missing CA certificate}
shift 2
shells=("$@")
[ "${#shells[@]}" -gt 0 ] || shells=(bash)

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

run_helper() {
  local shell_cmd=$1 root=$2 action=$3
  ZITI_CA_SOURCE="$root/compaan-ca.crt" \
  ZITI_CA_BUNDLE="$root/ca-certificates.crt" \
  ZITI_CA_LOCK="$root/update.lock" \
    $shell_cmd "$helper" "$action"
}
```

For each shell command, create a fresh directory and a stock self-signed CA:

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -subj '/CN=stock-test-ca' -days 1 \
  -keyout "$root/stock.key" -out "$root/stock.crt" >/dev/null 2>&1
cp "$root/stock.crt" "$root/ca-certificates.crt"
cp "$ca" "$root/compaan-ca.crt"
```

Use these exact marker values in tests:

```bash
begin='# BEGIN ziti-edge-tunnel managed compaan-ca'
end='# END ziti-edge-tunnel managed compaan-ca'
```

Add cases for these behaviors:

1. `ensure` adds one begin marker and one end marker.
2. A second `ensure` keeps one managed block.
3. Replacing the bundle with `stock.crt` and running `ensure` restores the block.
4. `remove` restores a byte-identical copy of `stock.crt`.
5. An unmatched begin marker makes `ensure` fail without changing the bundle.
6. A missing source certificate makes `ensure` fail without changing the bundle.
7. Invalid PEM data makes `ensure` fail without changing the bundle.
8. A different valid self-signed CA fails fingerprint validation.
9. A held `flock` keeps a concurrent `ensure` process blocked until lock release.

Use this lock test pattern so the helper process does not inherit the held lock:

```bash
(
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
kill -0 "$helper_pid" || fail 'helper did not wait for the CA lock'
wait "$lock_holder"
wait "$helper_pid"
```

Print the final count as:

```bash
printf 'CA bundle tests: %s passed for %s shell(s)\n' "$case_count" "${#shells[@]}"
```

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/ca-bundle-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-ca-bundle \
  modules/nixos/core/certs/compaan-ca.crt \
  bash
```

Expected: FAIL because `update-ca-bundle` does not exist.

- [ ] **Step 3: Implement the minimal POSIX helper**

Create the helper with these constants and overrides:

```sh
#!/bin/sh
set -eu

CA_SOURCE=${ZITI_CA_SOURCE:-/etc/ssl/certs/compaan-ca.crt}
CA_BUNDLE=${ZITI_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
CA_LOCK=${ZITI_CA_LOCK:-/tmp/lock/ziti-edge-tunnel-ca.lock}
EXPECTED_FINGERPRINT='63:93:BC:6D:23:7E:19:14:0A:A2:4F:97:55:09:99:7A:D9:97:D5:EF:59:A5:61:18:E7:BF:0D:EA:33:F2:DD:06'
BEGIN_MARKER='# BEGIN ziti-edge-tunnel managed compaan-ca'
END_MARKER='# END ziti-edge-tunnel managed compaan-ca'

action=${1:-}
case "$action" in
        ensure|remove) ;;
        *) printf 'usage: %s ensure|remove\n' "$0" >&2; exit 2 ;;
esac
```

Use focused functions with these responsibilities:

```sh
fail() {
        printf 'ziti-edge-tunnel CA bundle: %s\n' "$*" >&2
        exit 1
}

validate_ca() {
        [ -f "$CA_SOURCE" ] && [ ! -L "$CA_SOURCE" ] || fail "invalid CA source: $CA_SOURCE"
        fingerprint=$(openssl x509 -in "$CA_SOURCE" -noout -fingerprint -sha256) || fail 'cannot parse Compaan CA'
        fingerprint=${fingerprint#*=}
        [ "$fingerprint" = "$EXPECTED_FINGERPRINT" ] || fail 'Compaan CA fingerprint mismatch'
        openssl x509 -in "$CA_SOURCE" -noout -text | awk '
          /X509v3 Basic Constraints/ { getline; if ($0 ~ /CA:TRUE/) found=1 }
          END { exit found ? 0 : 1 }
        ' || fail 'Compaan certificate is not a CA'
        openssl verify -CAfile "$CA_SOURCE" "$CA_SOURCE" >/dev/null 2>&1 || fail 'Compaan CA is not self-verifying'
}
```

Use one `awk` pass to remove complete managed blocks. Reject nested, unmatched, or incomplete markers:

```sh
strip_managed_blocks() {
        awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
          $0 == begin {
            if (inside) exit 2
            inside=1
            next
          }
          $0 == end {
            if (!inside) exit 2
            inside=0
            next
          }
          !inside { print }
          END { if (inside) exit 2 }
        ' "$CA_BUNDLE"
}
```

Acquire the lock before bundle inspection. Require a regular target bundle:

```sh
lock_dir=${CA_LOCK%/*}
[ "$lock_dir" != "$CA_LOCK" ] || fail "lock has no parent directory: $CA_LOCK"
mkdir -p "$lock_dir" || fail "cannot create lock directory: $lock_dir"
exec 9>"$CA_LOCK"
flock 9 || fail 'cannot acquire CA bundle lock'
[ -f "$CA_BUNDLE" ] && [ ! -L "$CA_BUNDLE" ] || fail "invalid CA bundle: $CA_BUNDLE"
```

Create temporary files in the bundle directory. Use `cp -p` before writing so the replacement keeps the original mode and owner:

```sh
bundle_dir=${CA_BUNDLE%/*}
replacement=$(mktemp "$bundle_dir/.ca-certificates.crt.XXXXXX") || fail 'cannot create bundle replacement'
content=$(mktemp "$bundle_dir/.ca-certificates.content.XXXXXX") || {
        rm -f "$replacement"
        fail 'cannot create bundle content file'
}
trap 'rm -f "$replacement" "$content"' EXIT HUP INT TERM
strip_managed_blocks >"$content" || fail 'malformed Compaan CA bundle markers'
cp -p "$CA_BUNDLE" "$replacement" || fail 'cannot preserve CA bundle metadata'
```

For `ensure`, call `validate_ca` and place the managed block before the stock bundle. This order lets mbedTLS load the CA:

```sh
if [ "$action" = ensure ]; then
        validate_ca
        printf '%s\n' "$BEGIN_MARKER" >"$replacement"
        cat "$CA_SOURCE" >>"$replacement"
        printf '%s\n' "$END_MARKER" >>"$replacement"
        cat "$content" >>"$replacement" || fail 'cannot append stock CA bundle'
        openssl verify -CAfile "$replacement" "$CA_SOURCE" >/dev/null 2>&1 || fail 'updated CA bundle does not trust Compaan CA'
else
        cat "$content" >"$replacement" || fail 'cannot write CA bundle replacement'
fi
```

For `remove`, do not require the source certificate. For both actions, finish with an atomic rename:

```sh
mv -f "$replacement" "$CA_BUNDLE" || fail 'cannot replace CA bundle'
rm -f "$content"
trap - EXIT HUP INT TERM
```

Reject any action except `ensure` and `remove` with exit code 2.

- [ ] **Step 4: Run the helper tests under Bash and BusyBox ash**

Run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/ca-bundle-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-ca-bundle \
  modules/nixos/core/certs/compaan-ca.crt \
  bash "$(command -v busybox) ash"
```

Expected: all CA bundle cases pass for both shells.

- [ ] **Step 5: Wire the helper test into the flake**

Add these bindings in `modules/packages/ziti-edge-tunnel-openwrt.nix`:

```nix
ca-bundle-helper = ../../nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-ca-bundle;
ca-bundle-test = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/ca-bundle-test.sh;
compaan-ca = ../../modules/nixos/core/certs/compaan-ca.crt;
```

Add this check beside the existing OpenWRT checks:

```nix
checks.ziti-edge-tunnel-openwrt-ca-bundle =
  pkgs.runCommand "ziti-edge-tunnel-openwrt-ca-bundle-test"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.busybox
        pkgs.openssl
        pkgs.util-linux
      ];
    }
    ''
      bash ${ca-bundle-test} ${ca-bundle-helper} ${compaan-ca} \
        bash "${pkgs.busybox}/bin/busybox ash"
      touch $out
    '';
```

Stage the two new files before a normal flake command so the git-backed flake source includes them.

- [ ] **Step 6: Run the new flake check**

Run:

```bash
git add \
  modules/packages/ziti-edge-tunnel-openwrt.nix \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-ca-bundle \
  nix/packages/ziti-edge-tunnel-openwrt/tests/ca-bundle-test.sh
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ca-bundle --no-link
```

Expected: exit 0 and both shell variants pass.

- [ ] **Step 7: Commit the helper**

```bash
git commit -S -m "feat(ziti): manage Compaan CA bundle"
```

---

### Task 2: Require CA trust before procd launch

**Files:**
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh:28-102,210-437`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel:7-18,196-213`

**Interfaces:**
- Consumes: `/usr/lib/ziti-edge-tunnel/update-ca-bundle ensure` from Task 1
- Produces: `CA_BUNDLE_HELPER=${ZITI_CA_BUNDLE_HELPER:-/usr/lib/ziti-edge-tunnel/update-ca-bundle}`
- Produces: fail-closed CA refresh before `procd_open_instance`

- [ ] **Step 1: Add failing service tests**

In `run_case`, export a helper path and create a mock helper:

```bash
export ZITI_CA_BUNDLE_HELPER="$root/bin/update-ca-bundle"
export TEST_CA_RESULT=success
export TEST_CA_COMMAND="$root/ca-command"
export TEST_START_ORDER="$root/start-order"
: >"$TEST_CA_COMMAND"
: >"$TEST_START_ORDER"
cat >"$ZITI_CA_BUNDLE_HELPER" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"$TEST_CA_COMMAND"
printf 'ca\n' >>"$TEST_START_ORDER"
[ "${TEST_CA_RESULT:-failure}" = success ]
MOCK
chmod 0755 "$ZITI_CA_BUNDLE_HELPER"
```

Change the `procd_open_instance` mock to record its order:

```bash
procd_open_instance() {
  printf 'procd\n' >>"$TEST_START_ORDER"
}
```

Add these cases:

```bash
case_ca_refresh_precedes_procd() {
  printf '{}\n' >"$TEST_IDENTITY"
  start_service
  assert_contains "$TEST_CA_COMMAND" 'ensure'
  [[ $(sed -n '1p' "$TEST_START_ORDER") = ca ]] || fail 'CA refresh did not run first'
  [[ $(sed -n '2p' "$TEST_START_ORDER") = procd ]] || fail 'procd did not run after CA refresh'
}

case_ca_refresh_failure_blocks_start() {
  printf '{}\n' >"$TEST_IDENTITY"
  export TEST_CA_RESULT=failure
  if start_service; then
    fail 'CA refresh failure started the service'
  fi
  assert_contains "$TEST_CA_COMMAND" 'ensure'
  [[ ! -s $root/procd-command ]] || fail 'CA refresh failure opened procd instance'
  assert_no_file "$root/run/resolv.conf.before"
}
```

Add both cases to the `run_case` list. Update the reported count by two.

Add the same helper mock and environment variables to `run_busybox_env_case`. Make the BusyBox start driver assert that `ensure` ran.

- [ ] **Step 2: Run service tests to verify RED**

Run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/run-managed \
  bash "$(command -v busybox) ash"
```

Expected: FAIL because `start_service` does not call the CA helper.

- [ ] **Step 3: Add the CA helper to the init script**

Add the configurable helper path near the existing command paths:

```sh
CA_BUNDLE_HELPER=${ZITI_CA_BUNDLE_HELPER:-/usr/lib/ziti-edge-tunnel/update-ca-bundle}
```

Add one focused function:

```sh
refresh_ca_bundle() {
        if ! "$CA_BUNDLE_HELPER" ensure; then
                log 'Compaan CA bundle refresh failed'
                return 1
        fi
}
```

Call it after the enabled check and before identity validation or resolver snapshots:

```sh
start_service() {
        load_ziti_config || return 1
        [ "$enabled" -eq 1 ] || return 0
        refresh_ca_bundle || return 1
```

Do not add the helper to `run_managed`. Only `start_service` owns pre-launch trust validation.

- [ ] **Step 4: Run service tests to verify GREEN**

Run the command from Step 2.

Expected: all local service tests pass under Bash and BusyBox ash.

- [ ] **Step 5: Run the flake service check**

Stage the modified files, then run:

```bash
git add \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service --no-link
```

Expected: exit 0 with the increased service test count.

- [ ] **Step 6: Commit the service integration**

```bash
git commit -S -m "fix(ziti): require Compaan CA before launch"
```

---

### Task 3: Package the CA and lifecycle scripts in r5

**Files:**
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh:4-103`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh:4-47`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/default.nix:101-114`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile:3-10,76-89`
- Modify: `modules/packages/ziti-edge-tunnel-openwrt.nix:13-31`

**Interfaces:**
- Consumes: helper and CA source from Tasks 1 and 2
- Produces: `ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk`
- Produces: live `postinst` ensure and final-removal `prerm` remove actions
- Produces: exact release-aware IPK validation

- [ ] **Step 1: Extend the IPK validator before changing the package**

Change the validator interface to require the release:

```bash
ipk=${1:?usage: verify-ipk.sh IPK ARCH VERSION RELEASE}
expected_arch=${2:?missing architecture}
expected_version=${3:?missing version}
expected_release=${4:?missing release}
```

Add these extracted paths:

```bash
helper=$tmp/data/usr/lib/ziti-edge-tunnel/update-ca-bundle
ca=$tmp/data/etc/ssl/certs/compaan-ca.crt
postinst=$tmp/control/postinst
prerm=$tmp/control/prerm
```

Require all four files. Require the exact package version:

```bash
grep -Fx "Version: ${expected_version}-r${expected_release}" "$control" >/dev/null
```

Validate file modes:

```bash
[[ $(stat -c %a "$helper") = 755 ]] || { printf 'CA helper mode is not 0755\n' >&2; exit 1; }
[[ $(stat -c %a "$ca") = 644 ]] || { printf 'Compaan CA mode is not 0644\n' >&2; exit 1; }
```

Validate the CA with OpenSSL and the expected fingerprint:

```bash
fingerprint=$(openssl x509 -in "$ca" -noout -fingerprint -sha256)
[[ ${fingerprint#*=} = '63:93:BC:6D:23:7E:19:14:0A:A2:4F:97:55:09:99:7A:D9:97:D5:EF:59:A5:61:18:E7:BF:0D:EA:33:F2:DD:06' ]] || {
  printf 'Compaan CA fingerprint mismatch\n' >&2
  exit 1
}
openssl x509 -in "$ca" -noout -text | grep -A1 -F 'X509v3 Basic Constraints' | grep -F 'CA:TRUE' >/dev/null
openssl verify -CAfile "$ca" "$ca" >/dev/null
```

Validate the lifecycle contract:

```bash
grep -F '/usr/lib/ziti-edge-tunnel/update-ca-bundle ensure' "$postinst" >/dev/null
grep -F 'IPKG_INSTROOT' "$postinst" >/dev/null
grep -F '/usr/lib/ziti-edge-tunnel/update-ca-bundle remove' "$prerm" >/dev/null
grep -F 'IPKG_INSTROOT' "$prerm" >/dev/null
```

- [ ] **Step 2: Add failing package mutation cases**

Change `validator-test.sh` to accept the expected release and pass it to the validator:

```bash
expected_release=${3:?missing expected release}
```

Add these mutators:

```bash
mutate_missing_ca() {
  rm -f "$1/etc/ssl/certs/compaan-ca.crt"
}

mutate_substituted_ca() {
  printf 'not the Compaan CA\n' >"$1/etc/ssl/certs/compaan-ca.crt"
}

mutate_missing_ca_helper() {
  rm -f "$1/usr/lib/ziti-edge-tunnel/update-ca-bundle"
}
```

Run the three new cases after the existing cases. Report `validator tests: 6 passed`.

Update `run_case` to call:

```bash
bash "$validator" "$root/mutated.ipk" mipsel_24kc 1.15.1 "$expected_release"
```

- [ ] **Step 3: Run the validator against r4 to verify RED**

Run:

```bash
nix build .#ziti-edge-tunnel-openwrt
ipk=$(printf '%s\n' result/ziti-edge-tunnel_1.15.1-r4_mipsel_24kc.ipk)
bash nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh \
  "$ipk" mipsel_24kc 1.15.1 5
```

Expected: FAIL because r4 lacks the CA, helper, lifecycle scripts, and r5 version.

- [ ] **Step 4: Copy the repository CA into the generated package tree**

In `default.nix`, extend `packageTree` after the `cp` and `chmod` commands:

```nix
mkdir -p $out/files/etc/ssl/certs
install -m0644 \
  ${../../../modules/nixos/core/certs/compaan-ca.crt} \
  $out/files/etc/ssl/certs/compaan-ca.crt
```

Do not add a second PEM file to the repository.

- [ ] **Step 5: Update the OpenWRT Makefile to r5**

Set:

```make
PKG_RELEASE:=5
```

Install the helper and CA in `Package/ziti-edge-tunnel/install`:

```make
	$(INSTALL_BIN) ./files/usr/lib/ziti-edge-tunnel/update-ca-bundle $(1)/usr/lib/ziti-edge-tunnel/update-ca-bundle
	$(INSTALL_DIR) $(1)/etc/ssl/certs
	$(INSTALL_DATA) ./files/etc/ssl/certs/compaan-ca.crt $(1)/etc/ssl/certs/compaan-ca.crt
```

Add the runtime post-install script:

```make
define Package/ziti-edge-tunnel/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
/usr/lib/ziti-edge-tunnel/update-ca-bundle ensure
endef
```

Add the removal script. It removes the block before an upgrade, downgrade, or final removal. A new r5 post-install script restores the block after an upgrade:

```make
define Package/ziti-edge-tunnel/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
/usr/lib/ziti-edge-tunnel/update-ca-bundle remove
endef
```

- [ ] **Step 6: Update flake validation inputs and release arguments**

Add `pkgs.openssl` to `checks.ziti-edge-tunnel-openwrt-ipk.nativeBuildInputs`.

Change the validator commands to:

```nix
bash ${verify-ipk} "$ipk" mipsel_24kc 1.15.1 5
bash ${validator-test} "$ipk" ${verify-ipk} 5
```

- [ ] **Step 7: Build and validate r5**

Stage all Task 3 files so the flake sees them. Run:

```bash
git add \
  modules/packages/ziti-edge-tunnel-openwrt.nix \
  nix/packages/ziti-edge-tunnel-openwrt/default.nix \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile \
  nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh \
  nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh
nix build .#ziti-edge-tunnel-openwrt
```

Expected output file:

```text
result/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk
```

Run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh \
  result/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk \
  mipsel_24kc 1.15.1 5
bash nix/packages/ziti-edge-tunnel-openwrt/tests/validator-test.sh \
  result/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk \
  nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh \
  5
```

Expected: the IPK validator passes and six malicious package mutations fail validation.

- [ ] **Step 8: Commit the package integration**

```bash
git commit -S -m "build(ziti): package Compaan CA in r5"
```

---

### Task 4: Document and verify the complete branch

**Files:**
- Modify: `docs/ziti-edge-tunnel-openwrt.md`
- Verify: all files changed since `23b11f92bf9647a7318a3bddace20cee7f17a063`

**Interfaces:**
- Consumes: complete r5 package from Tasks 1 through 3
- Produces: operator and troubleshooting guidance
- Produces: full local verification evidence and final IPK checksum

- [ ] **Step 1: Update the runbook**

Add a short section that states these facts:

- r5 installs `compaan-ca.crt` and adds one managed block to the system bundle.
- Package install and service start repair the managed block.
- Final package removal removes the block.
- `/etc/hosts` entries can override Ziti DNS for router applications.
- `nslookup` alone does not prove that curl uses the Ziti address.

Add these safe diagnostic commands:

```sh
grep -nF 'ha.compaan' /etc/hosts
ping -c 1 ha.compaan
openssl s_client -connect ha.compaan:443 -servername ha.compaan </dev/null \
  | openssl x509 -noout -issuer -fingerprint -sha256 -ext subjectAltName
curl -fsS https://ha.compaan/ -o /dev/null
```

Do not add the webhook path or secret.

- [ ] **Step 2: Run all focused tests**

Run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/ca-bundle-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/update-ca-bundle \
  modules/nixos/core/certs/compaan-ca.crt \
  bash "$(command -v busybox) ash"

bash nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/run-managed \
  bash "$(command -v busybox) ash"

bash scripts/tests/ziti-openwrt-tunnel-test.sh scripts/ziti-openwrt-tunnel.sh
```

Expected: all CA, service, and 14 operator cases pass.

- [ ] **Step 3: Run all focused Nix checks**

Run:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ca-bundle --no-link
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service --no-link
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk --no-link
nix build .#checks.x86_64-linux.ziti-openwrt-tunnel-script --no-link
```

Expected: all four checks exit 0.

- [ ] **Step 4: Run the full flake check**

Run:

```bash
nix flake check --accept-flake-config --print-build-logs
```

Expected: exit 0 with `all checks passed!`.

- [ ] **Step 5: Record the exact package checksum**

Run:

```bash
nix build .#ziti-edge-tunnel-openwrt
sha256sum result/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk
stat -c 'size=%s bytes' result/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk
```

Record the SHA-256 and size in the execution notes. Do not edit the plan with build-specific values.

- [ ] **Step 6: Validate documentation and diff scope**

Run:

```bash
git diff --check
git diff --stat 23b11f92bf9647a7318a3bddace20cee7f17a063
git status --short
```

Expected: no whitespace errors and only the approved CA, package, test, service, runbook, spec, and plan paths.

- [ ] **Step 7: Commit the runbook**

```bash
git add docs/ziti-edge-tunnel-openwrt.md
git commit -S -m "docs(ziti): document OpenWRT CA trust"
```

---

### Task 5: Review and squash-merge locally

**Files:**
- Review: branch diff from `23b11f92bf9647a7318a3bddace20cee7f17a063` to the feature head
- Preserve: unrelated paths on local `main`

**Interfaces:**
- Consumes: locally verified feature branch
- Produces: independently reviewed branch
- Produces: one signed local squash commit on `main`

- [ ] **Step 1: Request independent adversarial review**

Resolve the active canonical `reviewer` role. Use fresh context and explicit model or thinking overrides when the resolver provides them.

Give the reviewer:

- approved spec path;
- implementation plan path;
- base SHA `23b11f92bf9647a7318a3bddace20cee7f17a063`;
- current feature head SHA;
- changed files and diff;
- focused and full test evidence;
- package checksum;
- live acceptance criteria;
- instruction to report findings by severity with file and line references.

The reviewer must check certificate validation, marker parsing, atomic replacement, lock behavior, upgrade guards, BusyBox compatibility, package contents, and secret handling.

- [ ] **Step 2: Resolve every blocking finding with TDD**

For each behavior defect:

1. Add or strengthen a regression test.
2. Run the focused test and capture RED.
3. Apply the smallest fix.
4. Run the focused test and capture GREEN.
5. Run all affected Nix checks.
6. Create a signed fix commit.
7. Ask the reviewer to check the revised head.

Do not accept a review suggestion without technical validation.

- [ ] **Step 3: Verify branch signatures and cleanliness**

Run:

```bash
git status --short --branch
git log --show-signature --format=fuller 23b11f92bf9647a7318a3bddace20cee7f17a063..HEAD
git diff --check 23b11f92bf9647a7318a3bddace20cee7f17a063..HEAD
```

Expected: clean branch, valid signatures, and no diff errors.

- [ ] **Step 4: Recheck local main before integration**

In `/home/roche/nixdots`, run:

```bash
git status --short --branch
git log -3 --oneline --decorate
```

If local `main` advanced, identify the new paths. Preserve every unrelated change.

- [ ] **Step 5: Squash the feature onto local main**

Run from `/home/roche/nixdots`:

```bash
git merge --squash fix/ziti-openwrt-compaan-ca
git diff --cached --check
git diff --cached --name-only
```

Verify that only feature-owned paths are staged. Then create one signed commit:

```bash
git commit -S -m "fix(ziti): trust Compaan CA on OpenWRT"
```

Do not push.

- [ ] **Step 6: Verify the merged result**

Run from local `main`:

```bash
git verify-commit HEAD
nix flake check --accept-flake-config --print-build-logs
nix build .#ziti-edge-tunnel-openwrt
sha256sum result/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk
```

Compare the feature-owned paths on `main` with the feature branch. Expected: byte-identical paths and a clean `main` checkout.

---

### Task 6: Upgrade and verify the ASUS router

**Files:**
- Deploy: `result/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk`
- Use: `scripts/ziti-openwrt-tunnel.sh`
- Clean after success: `.worktrees/ziti-openwrt-compaan-ca` and `fix/ziti-openwrt-compaan-ca`

**Interfaces:**
- Consumes: signed merged r5 package from local `main`
- Produces: trusted router HTTPS, healthy Ziti tunnel, and live acceptance evidence

- [ ] **Step 1: Run safe pre-update checks**

Verify package version and fast service status:

```bash
ssh root@192.168.1.1 'opkg status ziti-edge-tunnel | grep -E "^(Package|Version|Status|Architecture):"'
timeout 15 ssh root@192.168.1.1 '/etc/init.d/ziti-edge-tunnel running'
```

Expected: r4 is installed and `running` exits 0 within 15 seconds.

Build an exact r4 rollback artifact from the recorded base commit:

```bash
nix build \
  'git+file:///home/roche/nixdots?rev=23b11f92bf9647a7318a3bddace20cee7f17a063#ziti-edge-tunnel-openwrt' \
  --out-link /tmp/ziti-edge-tunnel-r4
test -f /tmp/ziti-edge-tunnel-r4/ziti-edge-tunnel_1.15.1-r4_mipsel_24kc.ipk
```

Verify the routing correction and expected trust failure:

```bash
ssh root@192.168.1.1 '
  set -u
  ! grep -nF ha.compaan /etc/hosts || exit 1
  ping -c 1 -W 2 ha.compaan | head -n 2 || exit 1
  curl -fsS https://ha.compaan/ -o /dev/null
  rc=$?
  [ "$rc" -eq 60 ]
'
```

Expected: no hosts override, a Ziti synthetic address, and curl exit 60 before r5.

Verify that no process holds `/tmp/lock/procd_ziti-edge-tunnel.lock`. Then acquire it with nonblocking `flock` in a short subshell.

Do not call init-script stop or restart after a failed lock check.

- [ ] **Step 2: Run the normal r4 to r5 update**

From local `main`, run:

```bash
timeout 600 scripts/ziti-openwrt-tunnel.sh update
```

Expected: exit 0 without an init-script hang. Record elapsed time and the update log path.

- [ ] **Step 3: Verify package and CA state**

Run:

```bash
ssh root@192.168.1.1 '
  set -eu
  opkg status ziti-edge-tunnel | grep -E "^(Package|Version|Status|Architecture):"
  test -f /etc/ssl/certs/compaan-ca.crt
  test "$(openssl x509 -in /etc/ssl/certs/compaan-ca.crt -noout -fingerprint -sha256 | cut -d= -f2)" = \
    "63:93:BC:6D:23:7E:19:14:0A:A2:4F:97:55:09:99:7A:D9:97:D5:EF:59:A5:61:18:E7:BF:0D:EA:33:F2:DD:06"
  test "$(grep -cF "# BEGIN ziti-edge-tunnel managed compaan-ca" /etc/ssl/certs/ca-certificates.crt)" -eq 1
  test "$(grep -cF "# END ziti-edge-tunnel managed compaan-ca" /etc/ssl/certs/ca-certificates.crt)" -eq 1
'
```

Expected: `1.15.1-r5`, the expected fingerprint, and one managed block.

- [ ] **Step 4: Verify trusted HTTPS through Ziti**

Run without `--cacert`, `--resolve`, or `-k`:

```bash
ssh root@192.168.1.1 '
  curl -fsS https://ha.compaan/ -o /dev/null
  openssl s_client -connect ha.compaan:443 -servername ha.compaan </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -fingerprint -sha256 -ext subjectAltName
'
```

Expected: curl exits 0. The issuer is `compaan-ca`, and the subject alternative name contains `DNS:ha.compaan`.

Do not send the production webhook during this verification.

- [ ] **Step 5: Repeat the full tunnel acceptance**

Verify these conditions without reading credential contents:

- `running` exits 0 within 15 seconds.
- opkg reports r5 for `mipsel_24kc`.
- procd supervises `/usr/lib/ziti-edge-tunnel/run-managed`.
- exactly one wrapper and one tunnel process exist.
- the tunnel process is a child of the wrapper.
- the tunnel command includes `--dns-upstream 127.0.0.1`.
- no process holds the procd service lock.
- nonblocking `flock` reports the procd lock as free.
- the identity file is nonempty with mode `0600`.
- `/etc/openziti/enroll.jwt` is absent.
- `nslookup ha.compaan` resolves through Ziti.
- `nslookup openwrt.org` returns public A or AAAA records.

- [ ] **Step 6: Inspect filtered logs**

Run:

```bash
ssh root@192.168.1.1 'logread -e ziti-edge-tunnel'
```

Analyze only the latest r5 startup. Report embedded `ERROR` records, CA helper errors, DNS errors, and relevant warnings.

The syslog `daemon.err` facility alone is not an application error. Use the embedded Ziti severity.

- [ ] **Step 7: Roll back only after failed acceptance**

If any r5 package, CA, curl, or tunnel acceptance check fails, keep the feature worktree and branch. Reinstall the verified r4 artifact without a manual service stop or restart:

```bash
scp /tmp/ziti-edge-tunnel-r4/ziti-edge-tunnel_1.15.1-r4_mipsel_24kc.ipk \
  root@192.168.1.1:/tmp/
ssh root@192.168.1.1 '
  opkg install --force-downgrade \
    /tmp/ziti-edge-tunnel_1.15.1-r4_mipsel_24kc.ipk
  rm -f /tmp/ziti-edge-tunnel_1.15.1-r4_mipsel_24kc.ipk
'
```

Verify r4 package status, a running tunnel, and an absent managed CA block. Stop execution and report the failed r5 check plus rollback evidence.

If all r5 checks pass, do not run the rollback command.

- [ ] **Step 8: Clean only the owned feature worktree and branch**

After every live check passes, verify branch path identity and worktree cleanliness. Remove the local rollback link. Then run from `/home/roche/nixdots`:

```bash
rm -f /tmp/ziti-edge-tunnel-r4
git worktree remove /home/roche/nixdots/.worktrees/ziti-openwrt-compaan-ca
git worktree prune
git branch -D fix/ziti-openwrt-compaan-ca
```

Do not remove or change other worktrees or branches.

- [ ] **Step 9: Report completion evidence**

Report:

- signed local squash SHA;
- r5 IPK filename, size, and SHA-256;
- focused and full test results;
- update duration;
- package, CA fingerprint, and marker evidence;
- curl and certificate evidence;
- tunnel, lock, identity, JWT, and DNS evidence;
- relevant residual warnings;
- worktree and branch cleanup;
- confirmation that no push occurred.
