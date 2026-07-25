# Ziti Controller CA Trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the verified production OpenZiti control-plane root CA to the shared NixOS trust store so `https://ziti-controller.siyavula.com/zac/` validates without Firefox certificate exceptions.

**Architecture:** Copy only the public CA certificate from the production Kubernetes Secret after an exact SHA-256 fingerprint check, store it as a focused certificate asset, and reference it through the existing `security.pki.certificateFiles` list. Preserve the unrelated OpenZiti edge-root certificate already in Nixdots.

**Tech Stack:** Kubernetes (`kubectl` read-only access), OpenSSL, NixOS modules, Nix flakes, nixfmt, statix, git hooks

## Global Constraints

- Work only in `/home/roche/nixdots/.worktrees/ziti-controller-ca` on branch `chore/ziti-controller-ca`.
- Use `/home/roche/projects/siyavula.deploy/kubeconfigs/prod` for read-only cluster access.
- Expected SHA-256 fingerprint: `69:42:CD:49:D4:4D:DF:C0:C9:0E:81:C4:66:21:2B:70:2D:63:CA:F0:DE:CF:AC:EB:F9:E6:BE:AF:E0:4D:4A:99`.
- Copy only `openziti/openziti-controller-ctrl-plane-root-secret` key `ca.crt`; never read or write `tls.key`.
- Keep `modules/nixos/core/certs/ctrl-siyavula-com.crt` and its trust entry unchanged.
- Do not mutate Kubernetes or activate/deploy NixOS from this plan.
- This is a static Nix configuration and certificate asset change. The Testing Value Gate excludes a new automated test; use direct cryptographic verification, linting, Nix evaluation, and a system build instead.
- `statix` is not installed globally; the user approved running it through a temporary Nix shell.

---

### Task 1: Add and verify the OpenZiti controller trust anchor

**Files:**
- Create: `modules/nixos/core/certs/ziti-controller-siyavula-com.crt`
- Modify: `modules/nixos/core/security.nix:3-6`
- Reference: `docs/specs/2026-07-25-ziti-controller-ca-design.md`

**Interfaces:**
- Consumes: Kubernetes Secret `openziti/openziti-controller-ctrl-plane-root-secret`, key `ca.crt`.
- Produces: A single PEM-encoded CA certificate referenced by `security.pki.certificateFiles` and included in affected NixOS system trust stores.

- [ ] **Step 1: Confirm the worktree is clean and on the planned branch**

Run:

```sh
cd /home/roche/nixdots/.worktrees/ziti-controller-ca
git status --short --branch
```

Expected: branch `chore/ziti-controller-ca` with no uncommitted files before plan tracking begins. If the plan file itself is committed separately, the tree should be fully clean.

- [ ] **Step 2: Extract the public CA to a temporary file and fail closed on fingerprint mismatch**

Run:

```sh
cd /home/roche/nixdots/.worktrees/ziti-controller-ca

expected='69:42:CD:49:D4:4D:DF:C0:C9:0E:81:C4:66:21:2B:70:2D:63:CA:F0:DE:CF:AC:EB:F9:E6:BE:AF:E0:4D:4A:99'
tmp_ca=$(mktemp)
trap 'rm -f "$tmp_ca"' EXIT

kubectl \
  --kubeconfig /home/roche/projects/siyavula.deploy/kubeconfigs/prod \
  --namespace openziti \
  get secret openziti-controller-ctrl-plane-root-secret \
  --output jsonpath='{.data.ca\.crt}' \
  | base64 --decode > "$tmp_ca"

actual=$(openssl x509 -in "$tmp_ca" -noout -fingerprint -sha256 | cut -d= -f2)
printf 'expected=%s\nactual=%s\n' "$expected" "$actual"
test "$actual" = "$expected"
test "$(grep -c -- '-----BEGIN CERTIFICATE-----' "$tmp_ca")" -eq 1
if grep -q -- 'PRIVATE KEY' "$tmp_ca"; then
  echo 'Refusing to copy a file containing private key material' >&2
  exit 1
fi

install -m 0644 "$tmp_ca" modules/nixos/core/certs/ziti-controller-siyavula-com.crt
rm -f "$tmp_ca"
trap - EXIT
```

Expected: `actual` exactly equals `expected`; the destination contains one certificate and no private key. The `install` command must not run if any validation fails.

- [ ] **Step 3: Inspect the copied certificate metadata**

Run:

```sh
openssl x509 \
  -in modules/nixos/core/certs/ziti-controller-siyavula-com.crt \
  -noout -subject -issuer -serial -dates -fingerprint -sha256
```

Expected:

```text
subject=CN=openziti-controller-ctrl-plane-root
issuer=CN=openziti-controller-ctrl-plane-root
notBefore=Nov  7 11:06:27 2025 GMT
notAfter=Nov 15 11:06:27 2035 GMT
sha256 Fingerprint=69:42:CD:49:D4:4D:DF:C0:C9:0E:81:C4:66:21:2B:70:2D:63:CA:F0:DE:CF:AC:EB:F9:E6:BE:AF:E0:4D:4A:99
```

The serial line may appear between issuer and validity; it must remain unchanged from the cluster certificate.

- [ ] **Step 4: Wire the new certificate into the NixOS trust list**

Edit `modules/nixos/core/security.nix` so the complete certificate list is:

```nix
pki.certificateFiles = [
  ./certs/compaan-ca.crt
  ./certs/ctrl-siyavula-com.crt
  ./certs/ziti-controller-siyavula-com.crt
];
```

Do not rename, replace, or remove either existing certificate.

- [ ] **Step 5: Verify the live HTTPS chain against the committed root**

Run:

```sh
tmp_chain=$(mktemp -d)
trap 'rm -rf "$tmp_chain"' EXIT

openssl s_client \
  -connect ziti-controller.siyavula.com:443 \
  -servername ziti-controller.siyavula.com \
  -showcerts </dev/null 2>/dev/null \
  | awk -v dir="$tmp_chain" '
      /-----BEGIN CERTIFICATE-----/ {
        cert += 1
        path = sprintf("%s/cert-%d.pem", dir, cert)
        in_cert = 1
      }
      in_cert { print > path }
      /-----END CERTIFICATE-----/ { in_cert = 0 }
    '

test -s "$tmp_chain/cert-1.pem"
test -s "$tmp_chain/cert-2.pem"
openssl verify \
  -purpose sslserver \
  -CAfile modules/nixos/core/certs/ziti-controller-siyavula-com.crt \
  -untrusted "$tmp_chain/cert-2.pem" \
  "$tmp_chain/cert-1.pem"

rm -rf "$tmp_chain"
trap - EXIT
```

Expected:

```text
/tmp/.../cert-1.pem: OK
```

- [ ] **Step 6: Format and inspect the focused changes**

Run:

```sh
nix fmt -- modules/nixos/core/security.nix
git diff --check
git status --short
git diff -- modules/nixos/core/security.nix
git diff --no-index -- /dev/null modules/nixos/core/certs/ziti-controller-siyavula-com.crt || test $? -eq 1
```

Expected:

- `git diff --check` exits successfully.
- The Nix diff contains only the new `certificateFiles` entry.
- The certificate diff contains one PEM certificate and no private key.

- [ ] **Step 7: Stage the new file before flake-backed verification**

New untracked files are excluded from normal git-backed flake evaluation, so stage both implementation files before running Nix checks:

```sh
git add \
  modules/nixos/core/certs/ziti-controller-siyavula-com.crt \
  modules/nixos/core/security.nix

git diff --cached --check
git diff --cached --stat
```

Expected: two staged implementation files and no whitespace errors.

- [ ] **Step 8: Run the repository-prescribed Nix linter**

Run the user-approved temporary package without installing it globally:

```sh
nix shell nixpkgs#statix -c statix check .
```

Expected: exit code `0` with no statix findings. Stop and report the findings instead of continuing if lint fails.

- [ ] **Step 9: Run formatter and flake verification**

Run:

```sh
nix fmt -- --check modules/nixos/core/security.nix
nix flake check
```

Expected: both commands exit `0`; `nix flake check` ends with `all checks passed!`.

- [ ] **Step 10: Build an affected desktop NixOS closure without activating it**

Run:

```sh
nix build .#nixosConfigurations.kiptum.config.system.build.toplevel
```

Expected: exit code `0` and a `result` symlink to the built system closure. Do not run `nixos-rebuild switch`, `deploy`, or any activation command.

- [ ] **Step 11: Review the final staged diff**

Run:

```sh
git status --short --branch
git diff --cached --check
git diff --cached -- modules/nixos/core/security.nix
git diff --cached -- modules/nixos/core/certs/ziti-controller-siyavula-com.crt
```

Review criteria:

- Only the new CA asset and one `security.pki.certificateFiles` line are staged.
- The certificate fingerprint matches the approved value.
- Existing certificate entries are unchanged.
- No Kubernetes manifest, Firefox profile, Secret, private key, or unrelated file changed.

- [ ] **Step 12: Commit the verified implementation**

Run:

```sh
env -u PYTHONPATH git commit -m "fix(certs): trust ziti controller CA"
```

Expected: the configured pre-commit hooks run successfully and the commit includes exactly the two implementation files.

- [ ] **Step 13: Confirm the branch is clean and record completion evidence**

Run:

```sh
git status --short --branch
git log -3 --oneline
```

Expected: clean `chore/ziti-controller-ca` branch containing the design/plan commits followed by `fix(certs): trust ziti controller CA`. Report the exact fingerprint and the successful lint, flake-check, and NixOS-build commands. Note that runtime Firefox verification remains pending until the user activates the NixOS configuration and restarts Firefox.
