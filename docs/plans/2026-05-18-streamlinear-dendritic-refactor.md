# Streamlinear Dendritic Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Streamlinear as `inputs.nixdots.packages.${pkgs.system}.streamlinear` while preserving Home Manager token injection and the MCP socket service.

**Architecture:** Split the raw npm package build from Home Manager integration. A flake-parts package module exposes the raw package; a reusable Home Manager module wraps that raw package only when `programs.streamlinear` is enabled. The local desktop profile imports the reusable module and configures SOPS-backed token injection.

**Tech Stack:** Nix flakes, flake-parts, Home Manager modules, `pkgs.buildNpmPackage`, `pkgs.writeShellScriptBin`, systemd user units, sops-nix.

---

## File structure

- Create `nix/packages/streamlinear.nix`
  - Owns the raw upstream package build.
  - Produces raw `bin/streamlinear` and `bin/streamlinear-cli` with no token handling.
- Create `modules/packages/streamlinear.nix`
  - Owns flake-parts `perSystem.packages.streamlinear` and `checks.streamlinear-build`.
- Create `modules/home/desktop/services/streamlinear/module.nix`
  - Owns the reusable Home Manager module factory.
  - Exposes `programs.streamlinear` options.
  - Builds local token-loading wrappers and systemd units.
- Modify `modules/home/desktop/services/streamlinear/default.nix`
  - Becomes this repo's local desktop profile wiring.
  - Imports `self.homeModules.streamlinear`.
  - Declares the existing SOPS secret and sets `programs.streamlinear.tokenFile`.
- Modify `flake.nix`
  - Imports `./modules/packages/streamlinear.nix`.
  - Exposes `flake.homeModules.streamlinear` from the same flake-parts module.
- Optionally modify `README.md`
  - Documents external package usage.

Keep the unrelated pre-existing change to `modules/home/desktop/utils/xdg/default.nix` out of this work unless the user explicitly asks to include it.

---

### Task 1: Extract the raw Streamlinear package and expose it as a flake package

**Files:**
- Create: `nix/packages/streamlinear.nix`
- Create: `modules/packages/streamlinear.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Verify the package output is currently missing**

Run:

```bash
nix eval .#packages.x86_64-linux.streamlinear.name
```

Expected: FAIL with an error like:

```text
error: flake 'path:/home/roche/nixdots' does not provide attribute 'packages.x86_64-linux.streamlinear.name'
```

- [ ] **Step 2: Create the raw package implementation**

Create `nix/packages/streamlinear.nix` with this content:

```nix
{ pkgs }:
let
  version = "unstable-2026-02-16";

  streamlinearSrc = pkgs.fetchFromGitHub {
    owner = "obra";
    repo = "streamlinear";
    rev = "ee5982c9b35ee94e0be9d27f43cdcc8902a40bca";
    hash = "sha256-UpKg176GWb1PafX/iq5SJ/wgPo+DX+8TQexooOo2fyU=";
  };

  streamlinearMcpSrc = pkgs.runCommand "streamlinear-mcp-src" { } ''
    cp -r ${streamlinearSrc}/mcp $out
    chmod -R u+w $out
  '';
in
pkgs.buildNpmPackage {
  pname = "streamlinear";
  inherit version;

  src = streamlinearMcpSrc;
  npmDepsHash = "sha256-4q09wELO1nE2oviJL4oScWXHVVnBTYnly58/Q1K92UA=";
  npmBuildScript = "build";

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/streamlinear $out/bin
    cp -r dist package.json node_modules $out/libexec/streamlinear/

    makeWrapper ${pkgs.nodejs}/bin/node $out/bin/streamlinear \
      --add-flags $out/libexec/streamlinear/dist/index.js

    makeWrapper ${pkgs.nodejs}/bin/node $out/bin/streamlinear-cli \
      --add-flags $out/libexec/streamlinear/dist/cli.js

    runHook postInstall
  '';

  meta = {
    description = "Linear CLI and MCP server from streamlinear";
    homepage = "https://github.com/obra/streamlinear";
    mainProgram = "streamlinear-cli";
  };
}
```

- [ ] **Step 3: Create the flake-parts package module**

Create `modules/packages/streamlinear.nix` with this content:

```nix
{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      streamlinear = import ../../nix/packages/streamlinear.nix { inherit pkgs; };
    in
    {
      packages.streamlinear = streamlinear;
      checks.streamlinear-build = streamlinear;
    };

  flake.homeModules.streamlinear = import ../home/desktop/services/streamlinear/module.nix { inherit self; };
}
```

This file references `modules/home/desktop/services/streamlinear/module.nix`, which is created in Task 2. It is acceptable for `nix eval .#packages.x86_64-linux.streamlinear.name` to fail until Task 2 creates that module, because flake output evaluation will parse this import.

- [ ] **Step 4: Import the package module from the flake**

In `flake.nix`, change the imports block from:

```nix
      imports = [
        ./hosts
        ./home
        ./pre-commit-hooks.nix
      ];
```

to:

```nix
      imports = [
        ./hosts
        ./home
        ./modules/packages/streamlinear.nix
        ./pre-commit-hooks.nix
      ];
```

- [ ] **Step 5: Stage new files so flake source includes them**

Run:

```bash
git add nix/packages/streamlinear.nix modules/packages/streamlinear.nix flake.nix
```

Expected: command exits with status 0.

Do not commit yet; Task 2 must add the referenced Home Manager module before the flake evaluates cleanly.

---

### Task 2: Create the reusable Home Manager module and local profile wiring

**Files:**
- Create: `modules/home/desktop/services/streamlinear/module.nix`
- Modify: `modules/home/desktop/services/streamlinear/default.nix`

- [ ] **Step 1: Replace the service implementation with a reusable module factory**

Create `modules/home/desktop/services/streamlinear/module.nix` with this content:

```nix
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    hasPrefix
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    ;

  cfg = config.programs.streamlinear;

  tokenLoader = optionalString (cfg.tokenFile != null) ''
    token_file=${lib.escapeShellArg cfg.tokenFile}
    if [ -z "''${LINEAR_API_TOKEN:-}" ] && [ -r "$token_file" ]; then
      export LINEAR_API_TOKEN="$(tr -d '\r\n' < "$token_file")"
    fi
  '';

  streamlinear = pkgs.writeShellScriptBin "streamlinear" ''
    set -euo pipefail
    ${tokenLoader}
    exec ${cfg.package}/bin/streamlinear "$@"
  '';

  streamlinearCli = pkgs.writeShellScriptBin "streamlinear-cli" ''
    set -euo pipefail
    ${tokenLoader}
    exec ${cfg.package}/bin/streamlinear-cli "$@"
  '';

  streamlinearMcpClient = pkgs.writeShellScriptBin "streamlinear-mcp-client" ''
    set -euo pipefail
    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    exec ${pkgs.socat}/bin/socat STDIO UNIX-CONNECT:"$runtime_dir/streamlinear/mcp.sock"
  '';

  streamlinearPackage = pkgs.symlinkJoin {
    name = "streamlinear-home-${cfg.package.version or "unknown"}";
    paths = [
      streamlinear
      streamlinearCli
      streamlinearMcpClient
    ];
  };
in
{
  options.programs.streamlinear = {
    enable = mkEnableOption "Streamlinear CLI and MCP Home Manager integration";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.system}.streamlinear;
      description = "Raw Streamlinear package to wrap for this Home Manager profile.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute path to a Linear API token file used by local wrappers when LINEAR_API_TOKEN is unset.";
    };

    mcpSocket.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable the socket-activated Streamlinear MCP user service.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile == null || hasPrefix "/" cfg.tokenFile;
        message = "programs.streamlinear.tokenFile must be null or an absolute path.";
      }
    ];

    home.packages = [ streamlinearPackage ];

    home.file.".config/streamlinear/README.md".text = ''
      # streamlinear

      The raw package is configured as:

        ${cfg.package}

      Local wrappers load LINEAR_API_TOKEN from:

        ${if cfg.tokenFile == null then "no token file configured" else cfg.tokenFile}

      LINEAR_API_TOKEN from the environment takes precedence over the token file.

      Installed commands:

      - streamlinear-cli        # direct CLI for search/get/update/comment/create/graphql
      - streamlinear            # stdio MCP server wrapper
      - streamlinear-mcp-client # connect to the user socket-activated MCP service

      User systemd units:

      - streamlinear-mcp.socket
      - streamlinear-mcp@.service
    '';

    systemd.user.sockets.streamlinear-mcp = mkIf cfg.mcpSocket.enable {
      Unit.Description = "streamlinear MCP socket";
      Socket = {
        ListenStream = "%t/streamlinear/mcp.sock";
        SocketMode = "0600";
        DirectoryMode = "0700";
        Accept = true;
        RemoveOnStop = true;
      };
      Install.WantedBy = [ "sockets.target" ];
    };

    systemd.user.services."streamlinear-mcp@" = mkIf cfg.mcpSocket.enable {
      Unit.Description = "streamlinear MCP server";
      Service = {
        Type = "simple";
        ExecStart = "${streamlinearPackage}/bin/streamlinear";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        Restart = "no";
      };
    };
  };
}
```

- [ ] **Step 2: Rewrite the local desktop profile wrapper**

Replace `modules/home/desktop/services/streamlinear/default.nix` with this content:

```nix
{
  config,
  inputs,
  self,
  ...
}:
let
  linearApiTokenPath = config.sops.secrets."linear-api-token".path;
in
{
  imports = [ self.homeModules.streamlinear ];

  sops.secrets."linear-api-token" = {
    sopsFile = "${inputs.nix-secrets}/secrets.yaml";
    path = "${config.home.homeDirectory}/.config/streamlinear/token";
    mode = "0400";
  };

  programs.streamlinear = {
    enable = true;
    tokenFile = linearApiTokenPath;
    mcpSocket.enable = true;
  };
}
```

- [ ] **Step 3: Stage the Home Manager module files**

Run:

```bash
git add modules/home/desktop/services/streamlinear/module.nix modules/home/desktop/services/streamlinear/default.nix
```

Expected: command exits with status 0.

- [ ] **Step 4: Verify the flake package output now evaluates**

Run:

```bash
nix eval .#packages.x86_64-linux.streamlinear.pname
```

Expected output:

```text
"streamlinear"
```

- [ ] **Step 5: Verify the Home Manager module output exists**

Run:

```bash
nix eval --impure --expr 'let flake = builtins.getFlake "path:/home/roche/nixdots"; in flake.homeModules ? streamlinear'
```

Expected output:

```text
true
```

---

### Task 3: Build and inspect the raw package

**Files:**
- Modify only if verification finds a packaging error: `nix/packages/streamlinear.nix`

- [ ] **Step 1: Build the raw package**

Run:

```bash
nix build .#streamlinear
```

Expected: command exits with status 0 and creates `result` pointing at the package store path.

- [ ] **Step 2: Confirm the raw package exposes the two reusable commands**

Run:

```bash
ls -l result/bin
```

Expected output includes:

```text
streamlinear
streamlinear-cli
```

- [ ] **Step 3: Confirm the raw commands do not contain token-file loading**

Run:

```bash
if grep -R "linear-api-token\|LINEAR_API_TOKEN=.*tr -d\|token_file=" result/bin result/libexec 2>/dev/null; then
  echo "unexpected token injection in raw package" >&2
  exit 1
fi
```

Expected: command exits with status 0 and prints nothing.

- [ ] **Step 4: If the package build fails because npm dependencies changed, update only `npmDepsHash`**

If `nix build .#streamlinear` reports a hash mismatch, edit `nix/packages/streamlinear.nix` and replace:

```nix
  npmDepsHash = "sha256-4q09wELO1nE2oviJL4oScWXHVVnBTYnly58/Q1K92UA=";
```

with the `got:` hash printed by Nix. Then rerun:

```bash
nix build .#streamlinear
```

Expected: command exits with status 0.

- [ ] **Step 5: Commit package extraction**

Run:

```bash
git add flake.nix nix/packages/streamlinear.nix modules/packages/streamlinear.nix modules/home/desktop/services/streamlinear/module.nix modules/home/desktop/services/streamlinear/default.nix
git commit -m "feat(streamlinear): expose reusable flake package"
```

Expected: commit succeeds with hooks passing. If hooks or signing fail because of sandbox restrictions, request escalated sandbox permissions and retry the commit without bypassing hooks or signing.

---

### Task 4: Verify Home Manager preserves local behavior

**Files:**
- Modify only if verification finds a module error:
  - `modules/home/desktop/services/streamlinear/module.nix`
  - `modules/home/desktop/services/streamlinear/default.nix`

- [ ] **Step 1: Build the Home Manager activation package for kiptum**

Run:

```bash
nix build .#homeConfigurations."roche@kiptum".activationPackage
```

Expected: command exits with status 0.

- [ ] **Step 2: Confirm the activation package contains the Streamlinear README text**

Run:

```bash
grep -R "The raw package is configured as" result 2>/dev/null | head -1
```

Expected output includes:

```text
The raw package is configured as
```

- [ ] **Step 3: Confirm the evaluated Home Manager config enables the MCP socket**

Run:

```bash
nix eval .#homeConfigurations."roche@kiptum".config.programs.streamlinear.mcpSocket.enable
```

Expected output:

```text
true
```

- [ ] **Step 4: Confirm the evaluated token file path remains the local SOPS path**

Run:

```bash
nix eval .#homeConfigurations."roche@kiptum".config.programs.streamlinear.tokenFile
```

Expected output:

```text
"/home/roche/.config/streamlinear/token"
```

- [ ] **Step 5: Commit Home Manager verification fixes if any were needed**

If Task 4 required code changes, run:

```bash
git add modules/home/desktop/services/streamlinear/module.nix modules/home/desktop/services/streamlinear/default.nix
git commit -m "fix(streamlinear): preserve home manager integration"
```

Expected: commit succeeds with hooks passing. If no code changes were needed, do not create an empty commit.

---

### Task 5: Document external flake usage

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a reusable package section to the README**

In `README.md`, add this section before `## Notes`:

````markdown
## Reusable Packages

This flake exposes selected tools for use from other development flakes.

### Streamlinear

Use the raw Streamlinear CLI package without Home Manager token injection:

```nix
pkgs.mkShell {
  packages = [ inputs.nixdots.packages.${pkgs.system}.streamlinear ];
}
```

The raw package provides `streamlinear-cli` and `streamlinear`. Set
`LINEAR_API_TOKEN` in the consuming shell or service environment.
````

- [ ] **Step 2: Stage the README change**

Run:

```bash
git add README.md
```

Expected: command exits with status 0.

- [ ] **Step 3: Commit the documentation**

Run:

```bash
git commit -m "docs(streamlinear): document reusable package"
```

Expected: commit succeeds with hooks passing. If hooks or signing fail because of sandbox restrictions, request escalated sandbox permissions and retry the commit without bypassing hooks or signing.

---

### Task 6: Final formatting and verification

**Files:**
- Modify only files changed by formatter:
  - `flake.nix`
  - `nix/packages/streamlinear.nix`
  - `modules/packages/streamlinear.nix`
  - `modules/home/desktop/services/streamlinear/module.nix`
  - `modules/home/desktop/services/streamlinear/default.nix`
  - `README.md`

- [ ] **Step 1: Run the formatter**

Run:

```bash
nix fmt
```

Expected: command exits with status 0.

- [ ] **Step 2: Stage formatter changes if any**

Run:

```bash
git add flake.nix nix/packages/streamlinear.nix modules/packages/streamlinear.nix modules/home/desktop/services/streamlinear/module.nix modules/home/desktop/services/streamlinear/default.nix README.md
```

Expected: command exits with status 0.

- [ ] **Step 3: Commit formatter changes if any**

Run:

```bash
if ! git diff --cached --quiet; then
  git commit -m "style(streamlinear): format dendritic refactor"
fi
```

Expected: either no output because there are no staged changes, or a commit succeeds with hooks passing.

- [ ] **Step 4: Run focused verification commands**

Run:

```bash
nix build .#streamlinear
nix build .#homeConfigurations."roche@kiptum".activationPackage
nix eval .#packages.x86_64-linux.streamlinear.pname
nix eval .#homeConfigurations."roche@kiptum".config.programs.streamlinear.tokenFile
```

Expected:

```text
nix build .#streamlinear exits 0
nix build .#homeConfigurations."roche@kiptum".activationPackage exits 0
"streamlinear"
"/home/roche/.config/streamlinear/token"
```

- [ ] **Step 5: Review final git state**

Run:

```bash
git status --short
```

Expected: only unrelated pre-existing changes may remain, such as:

```text
 M modules/home/desktop/utils/xdg/default.nix
```

There should be no unstaged or uncommitted Streamlinear refactor files.

---

## Self-review checklist

- Spec coverage:
  - Raw package output is covered by Tasks 1 and 3.
  - No token injection in raw package is covered by Task 3.
  - Home Manager token injection option is covered by Task 2.
  - Local SOPS-backed token path is covered by Task 2 and Task 4.
  - External dev flake usage is covered by Task 5.
- Placeholder scan: no placeholder steps remain; every code change has exact file content or exact inserted markdown.
- Type consistency:
  - The Home Manager option namespace is `programs.streamlinear` in every task.
  - The flake package name is `streamlinear` in every task.
  - The token option is `tokenFile` in every task.
  - The MCP option is `mcpSocket.enable` in every task.
