# OpenWRT Ziti DNS Upstream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward public DNS queries from the Ziti resolver to the local OpenWRT dnsmasq service.

**Architecture:** The UCI configuration supplies a `dns_upstream` value with a `127.0.0.1` default. The supervised tunnel command passes this value through `--dns-upstream` while preserving the standalone procd entrypoint.

**Tech Stack:** OpenWRT UCI, procd, POSIX shell, Bash test harnesses, Nix flakes, OpenWRT SDK, and opkg.

## Global Constraints

- Target OpenWRT 24.10.3 on `ramips/mt7621` with the `mipsel_24kc` package architecture.
- Limit Ziti interception to router-originated traffic.
- Keep `/usr/lib/ziti-edge-tunnel/run-managed` as the procd command.
- Do not source `/lib/functions/procd.sh` from the supervised wrapper.
- Preserve existing `/etc/config/ziti-edge-tunnel` files during upgrades.
- Use `127.0.0.1` as the default `dns_upstream` value.
- Increase `PKG_RELEASE` from 3 to 4.
- Use automated tests for the service behavior change.
- Use direct commands for static configuration and release-value verification.
- Keep all commits signed.
- Do not push any commit.
- Do not expose enrollment tokens or identity contents.

## File Structure

- `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel` loads UCI values and starts the managed tunnel.
- `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel` provides defaults for new installations.
- `nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh` exercises service behavior with fake tunnel and UCI functions.
- `nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile` defines the OpenWRT package release.
- `scripts/ziti-openwrt-tunnel.sh` remains unchanged and installs the exact built IPK.

The service test file is large because it contains shared OpenWRT shell harnesses. Add the focused DNS case without restructuring unrelated tests.

---

### Task 1: Add DNS upstream behavior and release r4

**Files:**
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh:35-45,78-84,262-271,403-443`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel:23-35,149-168`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel:1-5`
- Modify: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile:3-6`

**Interfaces:**
- Consumes: UCI option `main.dns_upstream` as an IPv4 resolver address.
- Produces: Shell variable `dns_upstream` with default `127.0.0.1`.
- Produces: Tunnel argument pair `--dns-upstream "$dns_upstream"`.
- Produces: `ziti-edge-tunnel_1.15.1-r4_mipsel_24kc.ipk`.

- [ ] **Step 1: Extend the service-test UCI stub**

Add this environment value beside the other `TEST_*` values in `run_case`:

```bash
export TEST_DNS_UPSTREAM=
```

Add this branch to the `config_get` case statement:

```bash
dns_upstream) printf -v "$1" '%s' "${TEST_DNS_UPSTREAM:-${4-}}" ;;
```

This branch uses the function default when the test does not set an override.

- [ ] **Step 2: Write the failing default-value assertion**

Add this assertion to `case_managed_exit_cleans_resolver` after the DNS-range assertion:

```bash
assert_contains "$TEST_RUN_COMMAND" '--dns-upstream 127.0.0.1'
```

- [ ] **Step 3: Write configured and invalid-value behavior tests**

Add this case after `case_managed_exit_cleans_resolver`:

```bash
case_configured_dns_upstream() {
  export TEST_DNS_UPSTREAM=192.0.2.54
  printf '{}\n' >"$TEST_IDENTITY"
  if ( run_managed ); then fail 'failed tunnel run succeeded'; fi
  assert_contains "$TEST_RUN_COMMAND" '--dns-upstream 192.0.2.54'
}
```

Add this invalid-value case after the configured-value case:

```bash
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
```

Register both cases after `managed-exit-cleanup`:

```bash
run_case configured-dns-upstream case_configured_dns_upstream
run_case invalid-dns-upstream case_invalid_dns_upstream_rejected
```

Increase the fixed `run_case` count in the final result from 11 to 13:

```bash
printf 'service tests: %s passed\n' "$((13 + signal_cases + busybox_cases + 1))"
```

- [ ] **Step 4: Run the service test and verify the RED state**

Run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/run-managed
```

Expected: FAIL with `run-command lacks: --dns-upstream 127.0.0.1`.

The failure must come from the missing production argument. Fix test syntax errors before production changes.

- [ ] **Step 5: Load and validate the UCI value**

Add this line to `load_ziti_config` before the `verbose` value:

```sh
config_get dns_upstream main dns_upstream 127.0.0.1
```

Add this POSIX-shell IPv4 validator before `load_ziti_config`:

```sh
validate_dns_upstream() {
        dns_address=$1
        case "$dns_address" in
                ''|.*|*.|*..*|*[!0-9.]*) return 1 ;;
        esac

        dns_old_ifs=$IFS
        IFS=.
        set -- $dns_address
        IFS=$dns_old_ifs
        [ "$#" -eq 4 ] || return 1

        for dns_octet; do
                case "$dns_octet" in
                        0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;;
                        *) return 1 ;;
                esac
        done
}
```

Call the validator in `load_ziti_config` before the `verbose` validation:

```sh
validate_dns_upstream "$dns_upstream" || {
        log "dns_upstream must be an IPv4 address: $dns_upstream"
        return 1
}
```

The pinned v1.15.1 binary ignores an invalid upstream-setter result. The init script must reject invalid and non-canonical values before tunnel start.

- [ ] **Step 6: Pass the upstream resolver to the tunnel**

Change the managed command to this form:

```sh
"$PROG" run \
        --identity "$identity_path" \
        --verbose "$verbose" \
        --dns-ip-range "$DNS_CIDR" \
        --dns-upstream "$dns_upstream" &
```

Keep the tunnel as the direct child of the standalone supervised wrapper.

- [ ] **Step 7: Add the packaged UCI default**

Add this line to the `main` section in the package configuration:

```text
        option dns_upstream '127.0.0.1'
```

Existing configuration files remain valid because `config_get` supplies the same runtime default.

- [ ] **Step 8: Increase the package release**

Change the release in the OpenWRT Makefile:

```make
PKG_RELEASE:=4
```

- [ ] **Step 9: Run the focused tests and verify the GREEN state**

Run the local service test:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/usr/lib/ziti-edge-tunnel/run-managed
```

Expected without BusyBox: `service tests: 16 passed`.

Run the operator tests:

```bash
bash scripts/tests/ziti-openwrt-tunnel-test.sh scripts/ziti-openwrt-tunnel.sh
```

Expected: `operator script tests: 14 passed`.

Run the Nix service check:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service --no-link
```

Expected: exit 0 with all BusyBox and shell cases. The result must report 19 service tests.

Run the operator-script check:

```bash
nix build .#checks.x86_64-linux.ziti-openwrt-tunnel-script --no-link
```

Expected: exit 0 with 14 operator tests.

- [ ] **Step 10: Verify static values directly**

Run:

```bash
grep -F "option dns_upstream '127.0.0.1'" \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel
grep -F 'PKG_RELEASE:=4' \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile
```

Expected: each command prints exactly one matching line.

No new automated test is necessary for these static values.

- [ ] **Step 11: Build and validate the r4 package**

Run:

```bash
nix build .#ziti-edge-tunnel-openwrt
```

Verify the exact result:

```bash
test -f result/ziti-edge-tunnel_1.15.1-r4_mipsel_24kc.ipk
test "$(find -L result -maxdepth 1 -type f -name 'ziti-edge-tunnel_*.ipk' | wc -l)" -eq 1
```

Run the package checks:

```bash
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-build --no-link
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk --no-link
```

Expected: exit 0. The IPK check must pass all three malicious-package mutations.

- [ ] **Step 12: Run the full feature-branch verification**

Run:

```bash
nix flake check --accept-flake-config --print-build-logs
```

Expected: exit 0 and `all checks passed!`.

- [ ] **Step 13: Review the diff and create a signed commit**

Run:

```bash
git diff --check
git status --short
git diff -- \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh
```

Stage only the four implementation files:

```bash
git add \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh
git commit -S -m "fix(ziti): forward public DNS through dnsmasq"
git verify-commit HEAD
```

Expected: the commit signature is valid. Do not bypass signing or hooks.

---

### Task 2: Review and squash-merge the verified fix

**Files:**
- Review: all changes from `main` to `fix/ziti-openwrt-dns-upstream`
- Modify: local `main` history through one signed squash commit

**Interfaces:**
- Consumes: signed feature branch with the design, plan, tests, and r4 package changes.
- Produces: one signed local `main` commit with the complete feature-tree content.

- [ ] **Step 1: Record review references**

Run:

```bash
BASE_SHA=$(git merge-base main fix/ziti-openwrt-dns-upstream)
HEAD_SHA=$(git rev-parse fix/ziti-openwrt-dns-upstream)
printf 'BASE=%s\nHEAD=%s\n' "$BASE_SHA" "$HEAD_SHA"
```

Use `docs/specs/2026-08-16-ziti-openwrt-dns-upstream-design.md` as the review requirements.

- [ ] **Step 2: Request an independent code review**

Dispatch the canonical Pi `reviewer` with fresh context. Include these items:

- The base and head SHAs.
- The approved design path.
- The full branch diff.
- The TDD red and green evidence.
- The focused checks and full flake result.
- The live failure that returned `REFUSED` for `openwrt.org`.
- The requirement to preserve the r3 procd-lock fix.

The reviewer must look for correctness, regressions, unsafe resolver loops, missing tests, and scope changes.

- [ ] **Step 3: Resolve review findings**

If the reviewer finds a defect, apply `receiving-code-review` before any change.

For behavior defects, add a failing test before the production fix. Then repeat Task 1 verification and create another signed commit.

If the reviewer finds no defect, record that result and continue.

- [ ] **Step 4: Squash-merge into local main**

Run these commands from `/home/roche/nixdots`:

```bash
git checkout main
git status --short --branch
git merge --squash fix/ziti-openwrt-dns-upstream
git commit -S -m "fix(ziti): forward public DNS through dnsmasq"
git verify-commit HEAD
```

Expected: the worktree is clean after the signed commit. Do not push.

- [ ] **Step 5: Verify the merged result**

Run:

```bash
nix flake check --accept-flake-config --print-build-logs
nix build .#ziti-edge-tunnel-openwrt
test -f result/ziti-edge-tunnel_1.15.1-r4_mipsel_24kc.ipk
git diff --quiet main fix/ziti-openwrt-dns-upstream -- \
  docs/plans/2026-08-16-ziti-openwrt-dns-upstream.md \
  docs/specs/2026-08-16-ziti-openwrt-dns-upstream-design.md \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh
```

Expected: all commands exit 0. All feature-owned paths must match the squash-commit content.

---

### Task 3: Upgrade and verify the router

**Files:**
- Execute: `scripts/ziti-openwrt-tunnel.sh`
- Inspect remotely: OpenWRT package, procd service, process table, lock descriptors, identity metadata, DNS, and logs

**Interfaces:**
- Consumes: merged r4 IPK from local `main`.
- Produces: live acceptance evidence without secret or identity content.

- [ ] **Step 1: Verify the safe r3 pre-upgrade state**

Run read-only router checks. Verify these facts before the update:

- The installed package is `1.15.1-r3`.
- `/etc/init.d/ziti-edge-tunnel running` returns within 15 seconds.
- procd supervises `/usr/lib/ziti-edge-tunnel/run-managed`.
- No process holds `/tmp/lock/procd_ziti-edge-tunnel.lock`.
- A nonblocking `flock` operation reports `FREE`.

Do not read the identity file.

- [ ] **Step 2: Run the fixed operator update**

Run from `/home/roche/nixdots`:

```bash
scripts/ziti-openwrt-tunnel.sh update
```

Apply a 10-minute outer timeout for evidence. Expected: exit 0 without a timeout and an r3-to-r4 opkg upgrade.

- [ ] **Step 3: Verify package and service behavior**

Verify these results with read-only SSH commands:

- `opkg status ziti-edge-tunnel` reports `Version: 1.15.1-r4`.
- `/etc/init.d/ziti-edge-tunnel running` exits 0 within 15 seconds.
- The procd command is `/usr/lib/ziti-edge-tunnel/run-managed`.
- Exactly one tunnel process runs under the standalone wrapper.
- No long-lived process holds `procd_ziti-edge-tunnel.lock`.
- A nonblocking lock operation reports `FREE`.

If a command hangs or fails, stop and use `systematic-debugging`. Do not guess or apply an untested router edit.

- [ ] **Step 4: Verify identity safety**

Inspect only file metadata.

Verify these results:

- `/etc/openziti/identities/router.json` exists and is not empty.
- Its mode string is `-rw-------`, which is mode `0600`.
- `/etc/openziti/enroll.jwt` is absent.

Do not print or copy identity contents.

- [ ] **Step 5: Verify Ziti and public DNS**

Run:

```bash
nslookup ha.compaan
nslookup openwrt.org
```

Expected: `ha.compaan` returns a `100.64.0.0/10` Ziti intercept address.

Expected: `openwrt.org` returns public IPv4 or IPv6 addresses without `REFUSED`.

Also verify that the process command contains `--dns-upstream 127.0.0.1`.

- [ ] **Step 6: Inspect filtered logs**

Run:

```bash
logread -e ziti-edge-tunnel
```

Filter the captured output for startup, DNS, resolver, warning, and error lines.

Record the service intercept entries and any remaining warnings. Redact token-shaped values before reporting evidence.

- [ ] **Step 7: Clean the merged worktrees and branches**

Run this step only after all live checks pass.

From `/home/roche/nixdots`, verify both feature trees match their squash commits. Then remove these owned worktrees if they exist:

```bash
git worktree remove .worktrees/ziti-openwrt-procd-lock
git worktree remove .worktrees/ziti-openwrt-dns-upstream
git worktree prune
```

Verify the squash-tree identities before branch deletion:

```bash
git diff --quiet 8ba37600 fix/ziti-openwrt-procd-lock
git diff --quiet main fix/ziti-openwrt-dns-upstream -- \
  docs/plans/2026-08-16-ziti-openwrt-dns-upstream.md \
  docs/specs/2026-08-16-ziti-openwrt-dns-upstream-design.md \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh
```

Squash commits do not make feature commits ancestors of `main`. Use the authorized force deletion after both identity checks pass:

```bash
git branch -D fix/ziti-openwrt-procd-lock
git branch -D fix/ziti-openwrt-dns-upstream
```

Verify a clean local `main`. Do not remove unrelated worktrees or branches.

- [ ] **Step 8: Report acceptance evidence**

Report these items:

- Signed squash commit SHA.
- Full flake-check exit status.
- Exact r4 IPK filename and checksum.
- Operator update duration and exit status.
- Prompt `running` command duration.
- procd command and process relationship.
- Lock-holder scan and nonblocking lock result.
- Identity mode and JWT absence.
- Ziti and public DNS results.
- Relevant filtered log findings.
- Cleanup status.
- Confirmation that no push occurred.
