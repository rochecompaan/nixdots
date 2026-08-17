# RepoWolf Home Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run one repository-scoped RepoWolf Home Manager user service on `kipchoge` and `kiptum`.

**Architecture:** A shared Home Manager module generates strict RepoWolf YAML, a protected sops-nix environment, and one user service. A focused policy module defines twelve repository and principal pairs. Each host uses separate TLS and client secrets from `inputs.nix-secrets`.

**Tech Stack:** Nix flakes, Home Manager, systemd user units, sops-nix, RepoWolf, OpenSSH, GitHub CLI, GPG or 1Password SSH agents.

**Design reference:** `docs/specs/2026-08-16-repowolf-service-design.md`

## Global Constraints

- Work only in `/home/roche/nixdots/.worktrees/repowolf-service` on `feat/repowolf-service`.
- Use `/home/roche/projects/nix-secrets/.worktrees/repowolf-secrets` for secret changes.
- Bind RepoWolf only to `172.17.0.1:8443` on both hosts.
- Run RepoWolf as the `roche` Home Manager user.
- Use the user GPG or 1Password SSH agent through `SSH_AUTH_SOCK`.
- Do not create a service user or deploy provider SSH private keys.
- Do not change the `roche-pi` repository.
- Do not change NixOS services, networking, firewall, LAN, or Ziti configuration.
- Do not run the RepoWolf OCI image.
- Do not add a shared endpoint, failover, or boot-time service before the user manager starts.
- Do not grant GitHub API operations to the `git.compaan` principals.
- Read encrypted source values from `${inputs.nix-secrets}/secrets.yaml`.
- Keep plaintext tokens and TLS private keys outside Git and the Nix store.
- Use one different client token for each principal and host combination.
- Give each principal access to one exact repository.
- Give `croprun` and `roche-pi` only `git:read` and `git:write`.
- Deny direct updates to every listed default branch.
- Deny all ref deletions and limit each push to 16 ref updates.
- Exclude `agent-jails` and `scaf`.
- Keep client integration out of scope.
- Put client guidance only in `modules/home/desktop/services/repowolf/README.md`.
- Use signed Conventional Commits and do not bypass hooks.
- Do not add text-based Nix or YAML tests. The approved Testing Value Gate rejects them.
- Use evaluation, builds, RepoWolf validation, and runtime checks instead.

## Planned File Structure

```text
modules/home/desktop/services/repowolf/
├── README.md                 # Client contract and integration guidance only
├── default.nix               # Options, sops resources, YAML, launcher, and user service
├── policy.nix                # Providers, repositories, principals, and Git policy
└── tls/
    ├── kipchoge-ca.crt       # Public CA certificate for kipchoge clients
    ├── kipchoge.crt          # Public server certificate for kipchoge
    ├── kiptum-ca.crt         # Public CA certificate for kiptum clients
    └── kiptum.crt            # Public server certificate for kiptum
```

The implementation also changes these files:

```text
flake.nix
flake.lock
home/roche/kipchoge.nix
home/roche/kiptum.nix
modules/home/desktop/services/default.nix
/home/roche/projects/nix-secrets/.gitignore
/home/roche/projects/nix-secrets/secrets.yaml
```

`default.nix` owns service integration. `policy.nix` owns static authorization data. The README owns the client contract.

## Execution Preparation

Run these commands before Task 1:

```sh
export NIXDOTS_WORKTREE=/home/roche/nixdots/.worktrees/repowolf-service
export NIX_SECRETS_REPO=/home/roche/projects/nix-secrets
export NIX_SECRETS_WORKTREE=/home/roche/projects/nix-secrets/.worktrees/repowolf-secrets
cd "$NIXDOTS_WORKTREE"
export IMPLEMENTATION_BASE="$(git rev-parse HEAD)"
test "$(git branch --show-current)" = feat/repowolf-service
test -z "$(git status --porcelain=v1)"
git verify-commit HEAD
```

Expected: the branch is `feat/repowolf-service`, the status is empty, and the signature is valid.

---

### Task 1: Add and lock the RepoWolf flake input

**Files:**
- Modify: `flake.nix:78-85`
- Modify: `flake.lock`

**Interfaces:**
- Produces: `inputs.repowolf.packages.${pkgs.system}.repowolf`
- Produces: one locked RepoWolf revision for certificate generation and runtime validation

- [ ] **Step 1: Add the RepoWolf input**

Add this block before the private `nix-secrets` input in `flake.nix`:

```nix
    repowolf = {
      url = "github:rochecompaan/repowolf";
      inputs.nixpkgs.follows = "nixpkgs";
    };
```

Keep the input blocks sorted by their existing functional groups. Do not change other inputs.

- [ ] **Step 2: Update only the RepoWolf lock node**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
nix flake lock --update-input repowolf
```

Expected: `flake.lock` adds RepoWolf nodes. Existing unrelated lock revisions do not change.

- [ ] **Step 3: Validate the locked input and package**

Run:

```sh
jq -e '
  .nodes.repowolf.locked.owner == "rochecompaan" and
  .nodes.repowolf.locked.repo == "repowolf" and
  .nodes.repowolf.inputs.nixpkgs == "nixpkgs"
' flake.lock >/dev/null

repowolf_ref="$(
  jq -r '.nodes.repowolf.locked | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock
)"
repowolf_store="$(nix build --no-link --print-out-paths "${repowolf_ref}#repowolf")"
test -x "$repowolf_store/bin/repowolf"
"$repowolf_store/bin/repowolf" config validate 2>&1 \
  | grep -F "invalid config arguments"
```

Expected: the package builds. The last command reaches the RepoWolf CLI and rejects the missing path.

- [ ] **Step 4: Review and commit the input**

Run:

```sh
nix fmt flake.nix
git diff --check
git diff -- flake.nix flake.lock
git add flake.nix flake.lock
git commit -S -m "build(flake): add RepoWolf input"
git verify-commit HEAD
```

Expected: the signed commit contains only `flake.nix` and `flake.lock`.

---

### Task 2: Prepare the isolated nix-secrets worktree

**Files:**
- Modify: `/home/roche/projects/nix-secrets/.gitignore:1-2`
- Create worktree: `/home/roche/projects/nix-secrets/.worktrees/repowolf-secrets`

**Interfaces:**
- Produces: a clean `feat/repowolf-secrets` worktree based on current `main`
- Produces: an ignored project-local worktree directory

- [ ] **Step 1: Recheck the external repository baseline**

Run from the normal nix-secrets checkout:

```sh
cd "$NIX_SECRETS_REPO"
test "$(git branch --show-current)" = main
test -z "$(git status --porcelain=v1)"
git fetch origin main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"
```

Expected: local `main` is clean and matches `origin/main`.

- [ ] **Step 2: Ignore the project-local worktree directory**

Append this exact entry to `.gitignore`:

```gitignore
.worktrees/
```

Then run:

```sh
cd "$NIX_SECRETS_REPO"
git diff --check
git add .gitignore
git commit -S -m "chore(git): ignore worktrees"
git verify-commit HEAD
git check-ignore -q .worktrees/probe
```

Expected: the signed commit changes only `.gitignore`. The final command exits with status `0`.

- [ ] **Step 3: Create the separate worktree**

Run:

```sh
cd "$NIX_SECRETS_REPO"
test ! -e "$NIX_SECRETS_WORKTREE"
git worktree add "$NIX_SECRETS_WORKTREE" -b feat/repowolf-secrets main
cd "$NIX_SECRETS_WORKTREE"
test "$(git branch --show-current)" = feat/repowolf-secrets
test -z "$(git status --porcelain=v1)"
```

Expected: the new path is a clean linked worktree on `feat/repowolf-secrets`.

---

### Task 3: Generate host TLS material and encrypted secrets

**Files:**
- Modify: `/home/roche/projects/nix-secrets/.worktrees/repowolf-secrets/secrets.yaml`
- Create: `modules/home/desktop/services/repowolf/tls/kipchoge-ca.crt`
- Create: `modules/home/desktop/services/repowolf/tls/kipchoge.crt`
- Create: `modules/home/desktop/services/repowolf/tls/kiptum-ca.crt`
- Create: `modules/home/desktop/services/repowolf/tls/kiptum.crt`
- Create outside Git: `${XDG_DATA_HOME:-$HOME/.local/share}/repowolf/ca/kipchoge-ca.key`
- Create outside Git: `${XDG_DATA_HOME:-$HOME/.local/share}/repowolf/ca/kiptum-ca.key`

**Interfaces:**
- Consumes: the locked RepoWolf revision from Task 1
- Produces: `repowolf/providers/github/token`
- Produces: `repowolf/tls/{kipchoge,kiptum}/private-key`
- Produces: 24 values below `repowolf/tokens/{kipchoge,kiptum}`
- Produces: public CA and server certificates for the Home Manager module

- [ ] **Step 1: Resolve the locked RepoWolf binary**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
repowolf_ref="$(
  jq -r '.nodes.repowolf.locked | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock
)"
repowolf_store="$(nix build --no-link --print-out-paths "${repowolf_ref}#repowolf")"
export REPOWOLF_ADMIN="$repowolf_store/bin/repowolf"
test -x "$REPOWOLF_ADMIN"
```

Expected: `REPOWOLF_ADMIN` points to the binary from the locked revision.

- [ ] **Step 2: Generate separate certificate sets**

Run:

```sh
set -euo pipefail
cd "$NIX_SECRETS_WORKTREE"

tls_tmp="$(mktemp -d)"
ca_archive="${XDG_DATA_HOME:-$HOME/.local/share}/repowolf/ca"
install -d -m 0700 "$ca_archive"
trap 'rm -rf "$tls_tmp"' EXIT

for host in kipchoge kiptum; do
  test ! -e "$ca_archive/${host}-ca.key"
  "$REPOWOLF_ADMIN" cert init \
    --output "$tls_tmp/$host" \
    --dns repowolf.internal \
    --dns host.docker.internal \
    --ip 172.17.0.1

  install -m 0600 "$tls_tmp/$host/ca.key" "$ca_archive/${host}-ca.key"
  install -Dm0644 \
    "$tls_tmp/$host/ca.crt" \
    "$NIXDOTS_WORKTREE/modules/home/desktop/services/repowolf/tls/${host}-ca.crt"
  install -Dm0644 \
    "$tls_tmp/$host/tls.crt" \
    "$NIXDOTS_WORKTREE/modules/home/desktop/services/repowolf/tls/${host}.crt"
done
```

Expected: each host has a different public certificate and private CA key.

- [ ] **Step 3: Encrypt the server private keys through standard input**

Run in the same shell before the cleanup trap runs:

```sh
for host in kipchoge kiptum; do
  jq -Rs . < "$tls_tmp/$host/tls.key" \
    | sops set --value-stdin \
        secrets.yaml \
        "[\"repowolf\"][\"tls\"][\"$host\"][\"private-key\"]"
done
```

Expected: each private key goes through a pipe. No private key appears in a process argument.

- [ ] **Step 4: Validate and encrypt the GitHub provider token**

Use the current authenticated GitHub token as the provider credential. Run:

```sh
provider_token="$(gh auth token)"
for repository in \
  alphaexplorationco/clubhouse_infra \
  alphaexplorationco/clubhouse_server \
  alphaexplorationco/clubhouse_analytics \
  upfrontsoftware/agibase \
  rochecompaan/repowolf \
  rochecompaan/nixdots \
  rochecompaan/homelab-k8s \
  rochecompaan/patchmill \
  upfrontsoftware/mycity \
  Siyavula/deploy
do
  GH_TOKEN="$provider_token" gh repo view "$repository" --json nameWithOwner >/dev/null
done

printf '%s' "$provider_token" \
  | jq -Rs . \
  | sops set --value-stdin \
      secrets.yaml \
      '["repowolf"]["providers"]["github"]["token"]'
unset provider_token
```

Expected: the credential can read all ten GitHub repositories. The token does not appear in arguments or output.

- [ ] **Step 5: Generate and encrypt all 24 client tokens**

Run:

```sh
principal_ids=(
  clubhouse-infra
  clubhouse-server
  clubhouse-analytics
  croprun
  agibase
  repowolf
  nixdots
  homelab-k8s
  patchmill
  mycity
  siyavula-deploy
  roche-pi
)

for host in kipchoge kiptum; do
  for principal in "${principal_ids[@]}"; do
    "$REPOWOLF_ADMIN" token generate \
      | tr -d '\n' \
      | jq -Rs . \
      | sops set --value-stdin \
          secrets.yaml \
          "[\"repowolf\"][\"tokens\"][\"$host\"][\"$principal\"]"
  done
done
```

Expected: every token travels through standard input. Token values do not appear in process arguments.

- [ ] **Step 6: Validate secret shape without printing values**

Run:

```sh
sops filestatus secrets.yaml | jq -e '.encrypted == true' >/dev/null

sops --decrypt --output-type json secrets.yaml \
  | jq -e '
      .repowolf as $r |
      ($r.providers.github.token | type == "string" and length > 0) and
      ($r.tls.kipchoge["private-key"] | startswith("-----BEGIN PRIVATE KEY-----")) and
      ($r.tls.kiptum["private-key"] | startswith("-----BEGIN PRIVATE KEY-----")) and
      ($r.tokens.kipchoge | length == 12) and
      ($r.tokens.kiptum | length == 12) and
      ([ $r.tokens.kipchoge[], $r.tokens.kiptum[] ] | length == 24) and
      ([ $r.tokens.kipchoge[], $r.tokens.kiptum[] ] | unique | length == 24)
    ' >/dev/null
```

Expected: sops reports encryption. The decrypted shape contains 24 unique client tokens and two private keys.

- [ ] **Step 7: Validate public certificates and private-file placement**

Run:

```sh
for host in kipchoge kiptum; do
  cert_dir="$NIXDOTS_WORKTREE/modules/home/desktop/services/repowolf/tls"
  openssl verify -CAfile "$cert_dir/${host}-ca.crt" "$cert_dir/${host}.crt"
  openssl x509 -in "$cert_dir/${host}.crt" -noout -checkhost repowolf.internal
  openssl x509 -in "$cert_dir/${host}.crt" -noout -checkhost host.docker.internal
  openssl x509 -in "$cert_dir/${host}.crt" -noout -checkip 172.17.0.1
  test "$(stat -c %a "$ca_archive/${host}-ca.key")" = 600
done

test "$(sha256sum \
  "$NIXDOTS_WORKTREE/modules/home/desktop/services/repowolf/tls/kipchoge.crt" \
  "$NIXDOTS_WORKTREE/modules/home/desktop/services/repowolf/tls/kiptum.crt" \
  | cut -d' ' -f1 | sort -u | wc -l)" -eq 2

test -z "$(
  find "$NIXDOTS_WORKTREE" "$NIX_SECRETS_WORKTREE" \
    -type f \( -name 'ca.key' -o -name 'tls.key' \) -print -quit
)"
```

Expected: both certificates validate. Both SAN checks pass. No private key file exists in either worktree.

- [ ] **Step 8: Commit the encrypted secret change**

Run:

```sh
cd "$NIX_SECRETS_WORKTREE"
git diff --check
git diff --stat
git add secrets.yaml
git commit -S -m "feat(repowolf): add service credentials"
git verify-commit HEAD
test -z "$(git status --porcelain=v1)"
```

Expected: the signed feature commit changes only encrypted `secrets.yaml`.

- [ ] **Step 9: Commit the public certificates in nixdots**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
git diff --check
git add modules/home/desktop/services/repowolf/tls
git commit -S -m "feat(repowolf): add host certificates"
git verify-commit HEAD
```

Expected: the signed commit contains four public certificate files and no private key.

- [ ] **Step 10: Squash the secret branch into private `main` and publish it**

Run from the normal nix-secrets checkout:

```sh
cd "$NIX_SECRETS_REPO"
test "$(git branch --show-current)" = main
test -z "$(git status --porcelain=v1)"
git merge --squash feat/repowolf-secrets
git commit -S -m "feat(repowolf): add service credentials"
git verify-commit HEAD
git push origin main
export NIX_SECRETS_REV="$(git rev-parse HEAD)"
test "$NIX_SECRETS_REV" = "$(git rev-parse origin/main)"
```

Expected: private `main` contains the encrypted values at a signed, published revision.

---

### Task 4: Pin the published nix-secrets revision

**Files:**
- Modify: `flake.lock`

**Interfaces:**
- Consumes: `NIX_SECRETS_REV` from Task 3
- Produces: a lock node that makes the encrypted RepoWolf keys available to Home Manager

- [ ] **Step 1: Update only the private input**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
export NIX_SECRETS_REV="$(git -C "$NIX_SECRETS_REPO" rev-parse main)"
nix flake lock --update-input nix-secrets
```

Expected: only the `nix-secrets` lock revision changes.

- [ ] **Step 2: Match the lock node to the published commit**

Run:

```sh
jq -e --arg revision "$NIX_SECRETS_REV" '
  .nodes["nix-secrets"].locked.rev == $revision
' flake.lock >/dev/null

test "$NIX_SECRETS_REV" = "$(git -C "$NIX_SECRETS_REPO" rev-parse origin/main)"
```

Expected: `flake.lock`, local private `main`, and `origin/main` name the same revision.

- [ ] **Step 3: Commit the lock update**

Run:

```sh
git diff --check
git diff -- flake.lock
git add flake.lock
git commit -S -m "chore(flake): pin RepoWolf secrets"
git verify-commit HEAD
```

Expected: the signed commit changes only `flake.lock`.

---

### Task 5: Define the shared repository policy

**Files:**
- Create: `modules/home/desktop/services/repowolf/policy.nix`

**Interfaces:**
- Produces: `providers`, `repositories`, `principals`, `principalIds`, and `tokenEnvironments`
- Produces: one repository grant for each principal
- Consumes later: `modules/home/desktop/services/repowolf/default.nix`

- [ ] **Step 1: Create the policy module**

Create `modules/home/desktop/services/repowolf/policy.nix` with this content:

```nix
let
  githubAgentCapabilities = [
    "repository:read"
    "issues:read"
    "issues:write"
    "pull_requests:read"
    "pull_requests:write"
    "actions:read"
    "statuses:read"
    "git:read"
    "git:write"
  ];

  gitOnlyAgentCapabilities = [
    "git:read"
    "git:write"
  ];

  repositorySpecs = [
    {
      id = "clubhouse-infra";
      tokenEnvironment = "REPOWOLF_TOKEN_CLUBHOUSE_INFRA";
      provider = "github-public";
      owner = "alphaexplorationco";
      name = "clubhouse_infra";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "clubhouse-server";
      tokenEnvironment = "REPOWOLF_TOKEN_CLUBHOUSE_SERVER";
      provider = "github-public";
      owner = "alphaexplorationco";
      name = "clubhouse_server";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "clubhouse-analytics";
      tokenEnvironment = "REPOWOLF_TOKEN_CLUBHOUSE_ANALYTICS";
      provider = "github-public";
      owner = "alphaexplorationco";
      name = "clubhouse_analytics";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "croprun";
      tokenEnvironment = "REPOWOLF_TOKEN_CROPRUN";
      provider = "compaan";
      owner = "roche";
      name = "croprun";
      defaultBranch = "main";
      capabilities = gitOnlyAgentCapabilities;
    }
    {
      id = "agibase";
      tokenEnvironment = "REPOWOLF_TOKEN_AGIBASE";
      provider = "github-public";
      owner = "upfrontsoftware";
      name = "agibase";
      defaultBranch = "master";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "repowolf";
      tokenEnvironment = "REPOWOLF_TOKEN_REPOWOLF";
      provider = "github-public";
      owner = "rochecompaan";
      name = "repowolf";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "nixdots";
      tokenEnvironment = "REPOWOLF_TOKEN_NIXDOTS";
      provider = "github-public";
      owner = "rochecompaan";
      name = "nixdots";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "homelab-k8s";
      tokenEnvironment = "REPOWOLF_TOKEN_HOMELAB_K8S";
      provider = "github-public";
      owner = "rochecompaan";
      name = "homelab-k8s";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "patchmill";
      tokenEnvironment = "REPOWOLF_TOKEN_PATCHMILL";
      provider = "github-public";
      owner = "rochecompaan";
      name = "patchmill";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "mycity";
      tokenEnvironment = "REPOWOLF_TOKEN_MYCITY";
      provider = "github-public";
      owner = "upfrontsoftware";
      name = "mycity";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "siyavula-deploy";
      tokenEnvironment = "REPOWOLF_TOKEN_SIYAVULA_DEPLOY";
      provider = "github-public";
      owner = "Siyavula";
      name = "deploy";
      defaultBranch = "master";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "roche-pi";
      tokenEnvironment = "REPOWOLF_TOKEN_ROCHE_PI";
      provider = "compaan";
      owner = "roche";
      name = "pi-config";
      defaultBranch = "main";
      capabilities = gitOnlyAgentCapabilities;
    }
  ];

  mkRepository = spec: {
    name = spec.id;
    value = {
      inherit (spec) provider owner name;
      git = {
        denyRefs = [ "refs/heads/${spec.defaultBranch}" ];
        denyDeletes = true;
        maxRefUpdates = 16;
      };
    };
  };

  mkPrincipal = spec: {
    name = spec.id;
    value = {
      tokenEnvs = [ spec.tokenEnvironment ];
      grants = [
        {
          repository = spec.id;
          inherit (spec) capabilities;
        }
      ];
    };
  };
in
{
  providers = {
    github-public = {
      kind = "github";
      apiHost = "github.com";
      gitHost = "github.com";
      sshUser = "git";
    };
    compaan = {
      kind = "github";
      apiHost = "git.compaan";
      gitHost = "git.compaan";
      sshUser = "git";
    };
  };

  repositories = builtins.listToAttrs (map mkRepository repositorySpecs);
  principals = builtins.listToAttrs (map mkPrincipal repositorySpecs);
  principalIds = map (spec: spec.id) repositorySpecs;
  tokenEnvironments = builtins.listToAttrs (
    map (spec: {
      name = spec.id;
      value = spec.tokenEnvironment;
    }) repositorySpecs
  );
}
```

- [ ] **Step 2: Evaluate every policy invariant**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
nix eval --json --file modules/home/desktop/services/repowolf/policy.nix \
  | jq -e '
      (.providers | keys | sort) == ["compaan", "github-public"] and
      (.repositories | length) == 12 and
      (.principals | length) == 12 and
      (.principalIds | length) == 12 and
      (.principalIds | unique | length) == 12 and
      ([.principals[] | .grants | length] | all(. == 1)) and
      ([.repositories[] | .git.denyDeletes] | all(. == true)) and
      ([.repositories[] | .git.maxRefUpdates] | all(. == 16)) and
      ([.repositories[] | .git.denyRefs | length] | all(. == 1)) and
      (.principals.croprun.grants[0].capabilities == ["git:read", "git:write"]) and
      (.principals["roche-pi"].grants[0].capabilities == ["git:read", "git:write"]) and
      (.repositories.croprun.provider == "compaan") and
      (.repositories["roche-pi"].provider == "compaan")
    ' >/dev/null

if rg -n '\b(agent-jails|scaf)\b' modules/home/desktop/services/repowolf/policy.nix; then
  exit 1
fi
```

Expected: the evaluation exits with status `0`. The exclusion scan prints nothing.

- [ ] **Step 3: Format and commit the policy**

Run:

```sh
nix fmt modules/home/desktop/services/repowolf/policy.nix
git diff --check
git add modules/home/desktop/services/repowolf/policy.nix
git commit -S -m "feat(repowolf): define repository policy"
git verify-commit HEAD
```

Expected: the signed commit adds only `policy.nix`.

---

### Task 6: Add the Home Manager service module

**Files:**
- Create: `modules/home/desktop/services/repowolf/default.nix`
- Modify: `modules/home/desktop/services/default.nix:2-13`

**Interfaces:**
- Consumes: `policy.nix`
- Consumes: `${inputs.nix-secrets}/secrets.yaml`
- Consumes: `inputs.repowolf.packages.${pkgs.system}.repowolf`
- Produces: `services.repowolf.{enable,hostName,package,sshAuthSock}`
- Produces: `$XDG_CONFIG_HOME/repowolf/repowolf.yaml`
- Produces: `$XDG_CONFIG_HOME/repowolf/tls/{ca.crt,tls.crt,tls.key}`
- Produces: `repowolf.service`

- [ ] **Step 1: Create the focused Home Manager module**

Create `modules/home/desktop/services/repowolf/default.nix` with this content:

```nix
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.services.repowolf;
  policy = import ./policy.nix;
  supportedHosts = [
    "kipchoge"
    "kiptum"
  ];

  configPath = "${config.xdg.configHome}/repowolf/repowolf.yaml";
  caCertificatePath = "${config.xdg.configHome}/repowolf/tls/ca.crt";
  certificatePath = "${config.xdg.configHome}/repowolf/tls/tls.crt";
  privateKeyPath = "${config.xdg.configHome}/repowolf/tls/tls.key";
  providerSecret = "repowolf/providers/github/token";
  privateKeySecret = "repowolf/tls/${cfg.hostName}/private-key";
  tokenSecret = principal: "repowolf/tokens/${cfg.hostName}/${principal}";

  yaml = pkgs.formats.yaml { };
  generatedConfig = yaml.generate "repowolf.yaml" {
    apiVersion = "repowolf.dev/v1alpha1";
    listen = "172.17.0.1:8443";
    tls = {
      certificate = certificatePath;
      privateKey = privateKeyPath;
    };
    tools = {
      gh = "${pkgs.gh}/bin/gh";
      ssh = "${pkgs.openssh}/bin/ssh";
    };
    inherit (policy) providers principals repositories;
  };

  tokenSecrets = builtins.listToAttrs (
    map (principal: {
      name = tokenSecret principal;
      value = {
        sopsFile = "${inputs.nix-secrets}/secrets.yaml";
        restartUnits = [ "repowolf.service" ];
      };
    }) policy.principalIds
  );

  environmentContent =
    lib.concatStringsSep "\n" (
      [ "GH_TOKEN=${config.sops.placeholder.${providerSecret}}" ]
      ++ map (
        principal:
        "${policy.tokenEnvironments.${principal}}=${config.sops.placeholder.${tokenSecret principal}}"
      ) policy.principalIds
    )
    + "\n";

  sshAuthSock =
    if cfg.sshAuthSock == null then
      ''"$(${pkgs.gnupg}/bin/gpgconf --list-dirs agent-ssh-socket)"''
    else
      lib.escapeShellArg cfg.sshAuthSock;

  launcher = pkgs.writeShellScript "repowolf-service" ''
    set -euo pipefail
    export SSH_AUTH_SOCK=${sshAuthSock}
    ${cfg.package}/bin/repowolf config validate --config ${lib.escapeShellArg configPath}
    exec ${cfg.package}/bin/repowolf serve --config ${lib.escapeShellArg configPath}
  '';
in
{
  options.services.repowolf = {
    enable = mkEnableOption "the RepoWolf repository access broker";

    hostName = mkOption {
      type = types.str;
      default = "";
      description = "Host name used to select RepoWolf TLS and token secrets.";
    };

    package = mkOption {
      type = types.package;
      default = inputs.repowolf.packages.${pkgs.system}.repowolf;
      defaultText = lib.literalExpression "inputs.repowolf.packages.${pkgs.system}.repowolf";
      description = "RepoWolf service and administration package.";
    };

    sshAuthSock = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional SSH-agent socket override. Null selects the GPG SSH-agent socket.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.elem cfg.hostName supportedHosts;
        message = "services.repowolf.hostName must be kipchoge or kiptum";
      }
      {
        assertion = cfg.sshAuthSock == null || cfg.sshAuthSock != "";
        message = "services.repowolf.sshAuthSock must be null or a non-empty path";
      }
    ];

    sops.secrets = tokenSecrets // {
      ${providerSecret} = {
        sopsFile = "${inputs.nix-secrets}/secrets.yaml";
        restartUnits = [ "repowolf.service" ];
      };
      ${privateKeySecret} = {
        sopsFile = "${inputs.nix-secrets}/secrets.yaml";
        path = privateKeyPath;
        mode = "0400";
        restartUnits = [ "repowolf.service" ];
      };
    };

    sops.templates."repowolf-service.env" = {
      content = environmentContent;
      mode = "0400";
    };

    xdg.configFile = {
      "repowolf/repowolf.yaml".source = generatedConfig;
      "repowolf/tls/ca.crt".source = ./tls/${cfg.hostName}-ca.crt;
      "repowolf/tls/tls.crt".source = ./tls/${cfg.hostName}.crt;
    };

    home.packages = [ cfg.package ];

    systemd.user.services.repowolf = {
      Unit = {
        Description = "RepoWolf repository access broker";
        X-Restart-Triggers = [
          generatedConfig
          ./tls/${cfg.hostName}.crt
        ];
      };
      Service = {
        EnvironmentFile = config.sops.templates."repowolf-service.env".path;
        ExecStart = launcher;
        NoNewPrivileges = true;
        PrivateTmp = false;
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
```

This module has one service-integration responsibility. Keep the policy data in `policy.nix`.

- [ ] **Step 2: Import the service module**

Add `./repowolf` after `./notes` in `modules/home/desktop/services/default.nix`:

```nix
    ./notes
    ./repowolf
    ./streamlinear
```

Do not change other imports.

- [ ] **Step 3: Stage new files before git-backed flake evaluation**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
git add \
  modules/home/desktop/services/default.nix \
  modules/home/desktop/services/repowolf/default.nix
```

This staging step is required. Git-backed flakes omit untracked files.

- [ ] **Step 4: Evaluate the disabled module and option declarations**

Run:

```sh
nix fmt \
  modules/home/desktop/services/default.nix \
  modules/home/desktop/services/repowolf/default.nix

git add \
  modules/home/desktop/services/default.nix \
  modules/home/desktop/services/repowolf/default.nix

for profile in roche@kipchoge roche@kiptum; do
  test "$(
    nix eval --raw \
      ".#homeConfigurations.\"$profile\".config.services.repowolf.enable"
  )" = false
  nix eval --raw \
    ".#homeConfigurations.\"$profile\".options.services.repowolf.package.description" \
    >/dev/null
done
```

Expected: both profiles expose the four RepoWolf options without enabling the service.

- [ ] **Step 5: Review and commit the module**

Run:

```sh
git diff --check
git diff --cached --stat
git diff --cached -- \
  modules/home/desktop/services/default.nix \
  modules/home/desktop/services/repowolf/default.nix
git commit -S -m "feat(repowolf): add Home Manager service"
git verify-commit HEAD
```

Expected: the signed commit contains only the service module and its import.

---

### Task 7: Enable RepoWolf on kipchoge and kiptum

**Files:**
- Modify: `home/roche/kipchoge.nix:18-30`
- Modify: `home/roche/kiptum.nix:14-27`

**Interfaces:**
- Consumes: `services.repowolf` from Task 6
- Produces: one enabled `repowolf.service` in each Home Manager profile
- Produces: host-specific sops secret references with one common policy

- [ ] **Step 1: Enable the kipchoge service**

Add this block after the `default` block in `home/roche/kipchoge.nix`:

```nix
  services.repowolf = {
    enable = true;
    hostName = "kipchoge";
  };
```

- [ ] **Step 2: Enable the kiptum service**

Add this block after the `default` block in `home/roche/kiptum.nix`:

```nix
  services.repowolf = {
    enable = true;
    hostName = "kiptum";
  };
```

Do not set `sshAuthSock` for the current GPG-agent configuration. A later 1Password change can set a user-owned socket path.

- [ ] **Step 3: Format and build both activation packages**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
nix fmt home/roche/kipchoge.nix home/roche/kiptum.nix
git add home/roche/kipchoge.nix home/roche/kiptum.nix

nix build '.#homeConfigurations."roche@kipchoge".activationPackage'
nix build '.#homeConfigurations."roche@kiptum".activationPackage'
```

Expected: both activation packages build with RepoWolf enabled.

- [ ] **Step 4: Validate each generated RepoWolf configuration**

Run:

```sh
for host in kipchoge kiptum; do
  profile="roche@$host"
  config_file="$(
    nix eval --raw \
      ".#homeConfigurations.\"$profile\".config.xdg.configFile.\"repowolf/repowolf.yaml\".source"
  )"
  package="$(
    nix eval --raw \
      ".#homeConfigurations.\"$profile\".config.services.repowolf.package.outPath"
  )"

  "$package/bin/repowolf" config validate --config "$config_file"

  nix shell nixpkgs#yq-go -c yq -e '
    .apiVersion == "repowolf.dev/v1alpha1" and
    .listen == "172.17.0.1:8443" and
    (.providers | length) == 2 and
    (.repositories | length) == 12 and
    (.principals | length) == 12 and
    (has("limits") | not) and
    .tls.certificate == "/home/roche/.config/repowolf/tls/tls.crt" and
    .tls.privateKey == "/home/roche/.config/repowolf/tls/tls.key" and
    .repositories.croprun.provider == "compaan" and
    .repositories."roche-pi".provider == "compaan" and
    .principals.croprun.grants[0].capabilities == ["git:read", "git:write"] and
    .principals."roche-pi".grants[0].capabilities == ["git:read", "git:write"] and
    (.tools.gh | test("^/nix/store/.*/bin/gh$")) and
    (.tools.ssh | test("^/nix/store/.*/bin/ssh$"))
  ' "$config_file" >/dev/null

  if grep -E '(GH_TOKEN=|REPOWOLF_TOKEN_[A-Z_]+=|ENC\[AES256_GCM)' "$config_file"; then
    exit 1
  fi
done
```

Expected: RepoWolf accepts both files. Each file has two providers and twelve exact grants. No secret value enters the YAML.

- [ ] **Step 5: Validate common policy and host-specific secret wiring**

Run:

```sh
policy_hashes="$(mktemp)"
trap 'rm -f "$policy_hashes"' EXIT

for host in kipchoge kiptum; do
  profile="roche@$host"
  config_file="$(
    nix eval --raw \
      ".#homeConfigurations.\"$profile\".config.xdg.configFile.\"repowolf/repowolf.yaml\".source"
  )"

  nix shell nixpkgs#yq-go -c yq -o=json \
    '{"providers": .providers, "repositories": .repositories, "principals": .principals}' \
    "$config_file" \
    | sha256sum \
    | cut -d' ' -f1 \
    >> "$policy_hashes"

  nix eval --json \
    ".#homeConfigurations.\"$profile\".config.sops.secrets" \
    | jq -e --arg host "$host" '
        (keys | length) >= 14 and
        has("repowolf/providers/github/token") and
        has("repowolf/tls/\($host)/private-key") and
        ([keys[] | select(startswith("repowolf/tokens/\($host)/"))] | length) == 12
      ' >/dev/null
done

test "$(sort -u "$policy_hashes" | wc -l)" -eq 1
```

Expected: both configurations have the same policy hash. Each profile references 12 host-specific tokens.

- [ ] **Step 6: Inspect the generated service unit without secrets**

Run:

```sh
for host in kipchoge kiptum; do
  profile="roche@$host"
  nix eval --json \
    ".#homeConfigurations.\"$profile\".config.systemd.user.services.repowolf" \
    | jq -e '
        .Service.NoNewPrivileges == true and
        .Service.PrivateTmp == false and
        .Service.Restart == "on-failure" and
        .Service.RestartSec == "5s" and
        .Service.UMask == "0077" and
        .Install.WantedBy == ["default.target"] and
        (.Service | has("ProtectHome") | not)
      ' >/dev/null
done
```

Expected: both units use the approved controls. Neither unit enables `ProtectHome`.

- [ ] **Step 7: Commit host enablement**

Run:

```sh
git diff --check
git diff --cached -- home/roche/kipchoge.nix home/roche/kiptum.nix
git commit -S -m "feat(repowolf): enable host services"
git verify-commit HEAD
```

Expected: the signed commit changes only the two Home Manager host profiles.

---

### Task 8: Document the client contract without client integration

**Files:**
- Create: `modules/home/desktop/services/repowolf/README.md`

**Interfaces:**
- Documents: host and Docker endpoints
- Documents: CA, token, environment, package, and restricted tool requirements
- Does not create: client packages, jails, container changes, or client configuration

- [ ] **Step 1: Write the service and endpoint guidance**

Create a README with these exact facts:

````markdown
# RepoWolf Home Service

This module runs RepoWolf as the `roche` Home Manager user on `kipchoge` and `kiptum`.
It does not configure RepoWolf clients.

## Endpoints

| Client location | Endpoint |
|---|---|
| Host process | `https://172.17.0.1:8443` |
| Docker container | `https://host.docker.internal:8443` |

On Linux, validate the Docker host mapping with this command:

```sh
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  alpine:3.22 \
  getent hosts host.docker.internal
```

Each host has a different public CA file at `~/.config/repowolf/tls/ca.crt`.
Give a client only the CA for its current host.
````

- [ ] **Step 2: Document the client environment and package**

Add these facts and example values:

````markdown
## Client contract

Each client gets one host-specific token for one repository principal.
It also gets the public CA for that host.

```sh
export REPOWOLF_ENDPOINT=https://172.17.0.1:8443
export REPOWOLF_TOKEN="$(cat /run/secrets/repowolf-token)"
export REPOWOLF_CA_FILE=/run/secrets/repowolf-ca.crt
export GIT_SSH_COMMAND=repowolf-git-ssh
```

A Docker client uses `https://host.docker.internal:8443` instead.
`REPOWOLF_SERVER_NAME` is optional because both approved endpoint names exist in the certificate.

Use `inputs.repowolf.packages.${pkgs.system}.repowolf-client` in Nix-managed clients.
Put that package's restricted `gh` before any unrestricted `gh` in `PATH`.
````

Do not add a real token or an encrypted token to the README.

- [ ] **Step 3: Document capability and credential boundaries**

Add these exact facts and mappings:

```markdown
## Principal map

| Principal | Provider | Repository |
|---|---|---|
| `clubhouse-infra` | `github-public` | `alphaexplorationco/clubhouse_infra` |
| `clubhouse-server` | `github-public` | `alphaexplorationco/clubhouse_server` |
| `clubhouse-analytics` | `github-public` | `alphaexplorationco/clubhouse_analytics` |
| `croprun` | `compaan` | `roche/croprun` |
| `agibase` | `github-public` | `upfrontsoftware/agibase` |
| `repowolf` | `github-public` | `rochecompaan/repowolf` |
| `nixdots` | `github-public` | `rochecompaan/nixdots` |
| `homelab-k8s` | `github-public` | `rochecompaan/homelab-k8s` |
| `patchmill` | `github-public` | `rochecompaan/patchmill` |
| `mycity` | `github-public` | `upfrontsoftware/mycity` |
| `siyavula-deploy` | `github-public` | `Siyavula/deploy` |
| `roche-pi` | `compaan` | `roche/pi-config` |

## Security boundaries

- `croprun` can use only `git:read` and `git:write` for `roche/croprun` on `git.compaan`.
- `roche-pi` can use only `git:read` and `git:write` for `roche/pi-config` on `git.compaan`.
- Every other principal has the approved GitHub and Git capabilities for one repository.
- A client must not receive `GH_TOKEN`, provider SSH keys, or the service `SSH_AUTH_SOCK`.
- A client must not mount the service environment, policy, certificate private key, or SSH-agent socket.
- Client integration belongs to a separate implementation session.
```

- [ ] **Step 4: Validate scope and commit the README**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
if rg -n '(BEGIN .*PRIVATE KEY|ghp_|github_pat_|REPOWOLF_TOKEN=[^"v])' \
  modules/home/desktop/services/repowolf/README.md; then
  exit 1
fi

pre-commit run --files modules/home/desktop/services/repowolf/README.md
git diff --check
git add modules/home/desktop/services/repowolf/README.md
git commit -S -m "docs(repowolf): document client contract"
git verify-commit HEAD
```

Expected: the signed commit adds only client guidance. It adds no client integration.

---

### Task 9: Run complete static verification and scope review

**Files:**
- Verify only: all implementation files from Tasks 1 through 8

**Interfaces:**
- Proves: both Home Manager closures build
- Proves: RepoWolf accepts both generated policies
- Proves: the full flake and hooks pass
- Proves: excluded scopes remain unchanged

- [ ] **Step 1: Run focused formatting and hook checks**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
nix fmt \
  flake.nix \
  home/roche/kipchoge.nix \
  home/roche/kiptum.nix \
  modules/home/desktop/services/default.nix \
  modules/home/desktop/services/repowolf/default.nix \
  modules/home/desktop/services/repowolf/policy.nix

test -z "$(git status --porcelain=v1)"
pre-commit run --all-files
```

Expected: formatting changes nothing. All hooks pass.

- [ ] **Step 2: Rebuild both Home Manager profiles**

Run:

```sh
nix build '.#homeConfigurations."roche@kipchoge".activationPackage'
nix build '.#homeConfigurations."roche@kiptum".activationPackage'
```

Expected: both builds exit with status `0`.

- [ ] **Step 3: Revalidate both generated configurations**

Run:

```sh
for host in kipchoge kiptum; do
  profile="roche@$host"
  config_file="$(
    nix eval --raw \
      ".#homeConfigurations.\"$profile\".config.xdg.configFile.\"repowolf/repowolf.yaml\".source"
  )"
  package="$(
    nix eval --raw \
      ".#homeConfigurations.\"$profile\".config.services.repowolf.package.outPath"
  )"
  "$package/bin/repowolf" config validate --config "$config_file"
done
```

Expected: both validation commands exit with status `0`.

- [ ] **Step 4: Run the full flake check**

Run:

```sh
nix flake check --accept-flake-config --print-build-logs
```

Expected: the full flake check exits with status `0`.

- [ ] **Step 5: Prove the implementation scope**

Run:

```sh
changed_files="$(git diff --name-only "$IMPLEMENTATION_BASE"..HEAD)"
printf '%s\n' "$changed_files"

if printf '%s\n' "$changed_files" | grep -E '^(modules/nixos/|hosts/)'; then
  exit 1
fi

if printf '%s\n' "$changed_files" | grep -E '(agent-jails|scaf|client)'; then
  test "$(printf '%s\n' "$changed_files" | grep -Ec '(agent-jails|scaf|client)')" -eq 0
fi

test -z "$(git status --porcelain=v1)"
test -z "$(
  git log --format='%G?' "$IMPLEMENTATION_BASE"..HEAD | grep -v '^G$'
)"
git log --show-signature --format='%h %G? %s' "$IMPLEMENTATION_BASE"..HEAD
```

Expected: no NixOS, host-system, jailed-agent, `scaf`, or client-integration file changed. Status is clean. Every new commit has `G` signature status.

- [ ] **Step 6: Verify the private repository state**

Run:

```sh
cd "$NIX_SECRETS_REPO"
test -z "$(git status --porcelain=v1)"
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"
git verify-commit main

cd "$NIX_SECRETS_WORKTREE"
test -z "$(git status --porcelain=v1)"
sops filestatus secrets.yaml | jq -e '.encrypted == true' >/dev/null
```

Expected: private `main` is published and signed. The linked worktree is clean. The secret file remains encrypted.

---

### Task 10: Activate and run host-local acceptance checks

**Files:**
- No repository files change

**Interfaces:**
- Proves: one active service per host
- Proves: the exact listener, TLS, SSH-agent, authorization, Git policy, and audit behavior

Run every step once on `kipchoge` and once on `kiptum`. Set `host` to the current host name.

- [ ] **Step 1: Activate the matching Home Manager profile**

Run on the target host:

```sh
host="$(hostname -s)"
case "$host" in
  kipchoge|kiptum) ;;
  *) exit 1 ;;
esac

cd "$NIXDOTS_WORKTREE"
home-manager switch --flake ".#roche@$host"
systemctl --user is-active repowolf.service
systemctl --user status repowolf.service --no-pager
```

Expected: activation succeeds. `repowolf.service` is active in the user manager.

- [ ] **Step 2: Validate the exact listener and certificate**

Run:

```sh
listeners="$(ss -H -ltn | awk '$4 ~ /:8443$/ { print $4 }')"
test "$listeners" = "172.17.0.1:8443"

openssl x509 \
  -in "$HOME/.config/repowolf/tls/tls.crt" \
  -noout \
  -checkip 172.17.0.1
openssl x509 \
  -in "$HOME/.config/repowolf/tls/tls.crt" \
  -noout \
  -checkhost host.docker.internal
openssl verify \
  -CAfile "$HOME/.config/repowolf/tls/ca.crt" \
  "$HOME/.config/repowolf/tls/tls.crt"
```

Expected: only `172.17.0.1:8443` listens. All certificate checks pass.

- [ ] **Step 3: Validate the service environment without printing values**

Run:

```sh
service_pid="$(systemctl --user show repowolf.service --property MainPID --value)"
expected_socket="$(gpgconf --list-dirs agent-ssh-socket)"

python - "$service_pid" "$expected_socket" <<'PY'
import pathlib
import sys

pid, expected_socket = sys.argv[1:]
entries = pathlib.Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
environment = dict(entry.split(b"=", 1) for entry in entries if b"=" in entry)
token_names = sorted(name for name in environment if name.startswith(b"REPOWOLF_TOKEN_"))
assert environment[b"SSH_AUTH_SOCK"].decode() == expected_socket
assert b"GH_TOKEN" in environment
assert len(token_names) == 12
print("ssh_agent_socket=expected")
print("provider_token_present=yes")
print("client_token_count=12")
PY
```

Expected: the socket matches the user GPG agent. The script prints names and counts only.

For a 1Password override, compare against `services.repowolf.sshAuthSock` instead of `gpgconf`.

- [ ] **Step 4: Build the locked client and load one token without printing it**

Run:

```sh
cd "$NIXDOTS_WORKTREE"
repowolf_ref="$(
  jq -r '.nodes.repowolf.locked | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock
)"
client_store="$(nix build --no-link --print-out-paths "${repowolf_ref}#repowolf-client")"
service_store="$(nix build --no-link --print-out-paths "${repowolf_ref}#repowolf")"

export REPOWOLF_ENDPOINT=https://172.17.0.1:8443
export REPOWOLF_CA_FILE="$HOME/.config/repowolf/tls/ca.crt"
export PATH="$client_store/bin:$PATH"
export GIT_SSH_COMMAND="$client_store/bin/repowolf-git-ssh"
export REPOWOLF_TOKEN="$(
  sops --decrypt \
    --extract "[\"repowolf\"][\"tokens\"][\"$host\"][\"nixdots\"]" \
    "$NIX_SECRETS_REPO/secrets.yaml"
)"
```

Expected: no command prints the token. The restricted `gh` is first in `PATH`.

- [ ] **Step 5: Prove allowed and denied GitHub repository access**

Run:

```sh
gh repo view --repo rochecompaan/nixdots --json nameWithOwner \
  | jq -e '.nameWithOwner == "rochecompaan/nixdots"' >/dev/null

if gh repo view --repo rochecompaan/repowolf --json nameWithOwner >/dev/null 2>&1; then
  exit 1
fi

unknown_token="$($service_store/bin/repowolf token generate)"
if REPOWOLF_TOKEN="$unknown_token" \
  gh repo view --repo rochecompaan/nixdots --json nameWithOwner >/dev/null 2>&1; then
  exit 1
fi
unset unknown_token
```

Expected: the valid token reads only `rochecompaan/nixdots`. The unknown token fails authentication.

- [ ] **Step 6: Prove Git SSH uses the service-side user agent**

Run:

```sh
git ls-remote git@github.com:rochecompaan/nixdots.git HEAD >/dev/null

export REPOWOLF_TOKEN="$(
  sops --decrypt \
    --extract "[\"repowolf\"][\"tokens\"][\"$host\"][\"roche-pi\"]" \
    "$NIX_SECRETS_REPO/secrets.yaml"
)"
git ls-remote git@git.compaan:roche/pi-config.git HEAD >/dev/null

if gh repo view --repo roche/pi-config --json nameWithOwner >/dev/null 2>&1; then
  exit 1
fi
```

Expected: both Git reads succeed through RepoWolf. The `roche-pi` token cannot use GitHub API operations.

- [ ] **Step 7: Prove protected branch, deletion, and update-count limits**

Load the `nixdots` token again. Then run all pushes from a temporary repository:

```sh
export REPOWOLF_TOKEN="$(
  sops --decrypt \
    --extract "[\"repowolf\"][\"tokens\"][\"$host\"][\"nixdots\"]" \
    "$NIX_SECRETS_REPO/secrets.yaml"
)"

test_repo="$(mktemp -d)"
trap 'rm -rf "$test_repo"' EXIT
git -C "$test_repo" init -q
git -C "$test_repo" config user.name "RepoWolf policy test"
git -C "$test_repo" config user.email "repowolf-policy-test@invalid"
printf 'policy test\n' > "$test_repo/probe.txt"
git -C "$test_repo" add probe.txt
git -C "$test_repo" commit -q -m "test: probe RepoWolf policy"

if git -C "$test_repo" push \
  git@github.com:rochecompaan/nixdots.git \
  HEAD:refs/heads/main; then
  exit 1
fi

if git -C "$test_repo" push \
  git@github.com:rochecompaan/nixdots.git \
  :refs/heads/repowolf-delete-probe; then
  exit 1
fi

refspecs=()
for number in $(seq 1 17); do
  refspecs+=("HEAD:refs/heads/repowolf-limit-probe-$number")
done
if git -C "$test_repo" push \
  git@github.com:rochecompaan/nixdots.git \
  "${refspecs[@]}"; then
  exit 1
fi
```

Expected: all three pushes fail before any provider ref changes.

- [ ] **Step 8: Validate sanitized accepted and denied audit events**

Run the following after Steps 5 through 7:

```sh
journal_file="$(mktemp)"
trap 'rm -f "$journal_file"; rm -rf "$test_repo"' EXIT
journalctl --user -u repowolf.service --since '-10 minutes' --output cat > "$journal_file"

python - "$journal_file" "$NIX_SECRETS_REPO/secrets.yaml" <<'PY'
import json
import pathlib
import subprocess
import sys

journal_path, secrets_path = sys.argv[1:]
journal = pathlib.Path(journal_path).read_text()
records = [json.loads(line) for line in journal.splitlines() if line.startswith("{")]
allowed_fields = {
    "timestamp", "request_id", "principal", "provider", "repository",
    "operation", "outcome", "reason", "duration_ms", "input_bytes",
    "output_bytes", "refs", "update_count",
}
assert records
assert any(record.get("outcome") == "accepted" for record in records)
assert any(record.get("outcome") == "denied" for record in records)
assert all(set(record) <= allowed_fields for record in records)

secrets = json.loads(subprocess.check_output(
    ["sops", "--decrypt", "--output-type", "json", secrets_path],
    text=True,
))
repowolf = secrets["repowolf"]

def string_values(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from string_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from string_values(child)

forbidden = list(string_values(repowolf))
assert all(secret not in journal for secret in forbidden if secret)
print("accepted_audit_event=yes")
print("denied_audit_event=yes")
print("secret_leaks=0")
PY
```

Expected: the journal contains accepted and denied events. It contains no provider or client token.

- [ ] **Step 9: Record host-local acceptance evidence**

Run:

```sh
systemctl --user is-active repowolf.service
ss -H -ltn | awk '$4 ~ /:8443$/ { print $4 }'
journalctl --user -u repowolf.service -n 20 --output cat \
  | jq -R 'fromjson? | {timestamp, principal, provider, repository, operation, outcome, reason}'
```

Expected: the output identifies the host, exact listener, and sanitized audit metadata. Do not commit runtime output.

## Completion Gate

Before branch integration, make sure that all Task 9 checks pass. Then make sure that Task 10 passes on both hosts.

Use `superpowers:requesting-code-review` before integration. Give the reviewer the approved spec, this plan, the implementation base, and the feature head.

After review, use `superpowers:finishing-a-development-branch`. Offer a local squash merge into `main`, as required by this repository.
