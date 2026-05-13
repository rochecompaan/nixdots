# Roche Pi Dendritic Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `modules/home/desktop/utils/pi` into a personal-first dendritic `roche-pi` flake targeting `x86_64-linux`, then consume it from `nixdots`.

**Architecture:** Create `/home/roche/projects/pi/roche-pi` as a flake-parts + import-tree repository with resource files under `resources/` and output-producing modules under `modules/`. Build a store-backed `pi-config` package, expose Home Manager modules and project shell helpers, then replace the local `nixdots` Pi module with the external module.

**Tech Stack:** Nix flakes, flake-parts, import-tree, Home Manager modules, Pi package manifests, Nix store path package sources, x86_64-linux.

---

## File Structure

### New repository: `/home/roche/projects/pi/roche-pi`

- Create: `flake.nix` — minimal dendritic entrypoint using `flake-parts` and `import-tree`.
- Create: `README.md` — usage docs for Home Manager and project/devenv consumers.
- Create: `package.json` — Pi package manifest for `extensions`, `skills`, and `themes`.
- Create: `modules/parts.nix` — x86_64-linux systems and flake-parts imports.
- Create: `modules/packages/pi-config.nix` — packages `pi-config` and `default`.
- Create: `modules/packages/pi-deps.nix` — Nix-built Pi package dependencies copied from current `files.nix`.
- Create: `modules/packages/pi-remote.nix` — extracted `@noahsaso/pi-remote` derivation.
- Create: `modules/packages/notion-cli.nix` — extracted Notion CLI derivation.
- Create: `modules/home/pi.nix` — `programs.roche-pi` Home Manager module and `homeModules.default` export.
- Create: `modules/home/jailed-pi.nix` — optional placeholder/export for future jailed migration, initially disabled by default.
- Create: `modules/lib/settings.nix` — pure settings builder.
- Create: `modules/lib/theme.nix` — pure Pi theme builder from Base16 colors.
- Create: `modules/lib/project-pi.nix` — `projectPiShellHook` builder.
- Create: `modules/devshells/default.nix` — a validation shell with `pi`, `jq`, `nixfmt-rfc-style`, and `git`.
- Copy: `resources/extensions/**` from `nixdots/modules/home/desktop/utils/pi/extensions/**`.
- Copy: `resources/skills/**` from `nixdots/modules/home/desktop/utils/pi/skills/**`.
- Copy: `resources/agents/**` from `nixdots/modules/home/desktop/utils/pi/agents/**`.
- Copy: `resources/agent-teams/**` from `nixdots/modules/home/desktop/utils/pi/agent-teams/**`.
- Copy: `resources/settings.json` from `nixdots/modules/home/desktop/utils/pi/settings.json`.
- Copy: `resources/pi-remote-package-lock.json` from `nixdots/modules/home/desktop/utils/pi/pi-remote-package-lock.json`.
- Create: root symlinks `extensions`, `skills`, `agents`, `agent-teams`, and `themes` to their matching `resources/*` directories for local development convenience.

### Existing repository: `/home/roche/nixdots`

- Modify: `flake.nix` — add either a temporary local `path:` `roche-pi` input for validation or the final `github:` input after the new repo is pushed.
- Modify: `modules/home/desktop/utils/default.nix` — keep `./pi` import for now until replacement is stable, then remove it.
- Modify: `modules/home/desktop/utils/pi/default.nix` — replace local file wiring with `inputs.roche-pi.homeModules.default` import and `programs.roche-pi` configuration.
- Modify: `modules/home/desktop/utils/jailed-agents/default.nix` — defer full migration; only update after base Home Manager path verifies.

---

## Task 1: Bootstrap the dendritic `roche-pi` repository

**Files:**
- Create: `/home/roche/projects/pi/roche-pi/flake.nix`
- Create: `/home/roche/projects/pi/roche-pi/modules/parts.nix`
- Create: `/home/roche/projects/pi/roche-pi/README.md`
- Create: `/home/roche/projects/pi/roche-pi/package.json`

- [ ] **Step 1: Create the repository directory**

Run:

```bash
mkdir -p /home/roche/projects/pi/roche-pi/modules
cd /home/roche/projects/pi/roche-pi
git init
```

Expected: Git reports an initialized repository at `/home/roche/projects/pi/roche-pi/.git/`.

- [ ] **Step 2: Create `flake.nix`**

Write `/home/roche/projects/pi/roche-pi/flake.nix`:

```nix
{
  description = "Roché Compaan's personal Pi configuration package";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    flake-parts.url = "github:hercules-ci/flake-parts";

    import-tree.url = "github:vic/import-tree";

    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
```

- [ ] **Step 3: Create `modules/parts.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/parts.nix`:

```nix
{ inputs, ... }:
{
  imports = [
    inputs.home-manager.flakeModules.home-manager
  ];

  systems = [ "x86_64-linux" ];
}
```

- [ ] **Step 4: Create root `package.json`**

Write `/home/roche/projects/pi/roche-pi/package.json`:

```json
{
  "name": "@roche/pi-config",
  "version": "0.1.0",
  "private": true,
  "description": "Roché Compaan's personal Pi extensions, skills, agents, themes, and Nix packaging",
  "keywords": ["pi-package"],
  "pi": {
    "extensions": ["./resources/extensions"],
    "skills": ["./resources/skills"],
    "themes": ["./resources/themes"]
  }
}
```

- [ ] **Step 5: Create initial `README.md`**

Write `/home/roche/projects/pi/roche-pi/README.md`:

```markdown
# roche-pi

Personal-first Pi configuration packaged as a dendritic Nix flake.

Initial platform support is `x86_64-linux` only.

The examples below are valid once the Home Manager module and project helper modules are implemented in later tasks.

## Home Manager usage

```nix
{
  inputs.roche-pi.url = "github:rochecompaan/roche-pi";

  imports = [ inputs.roche-pi.homeModules.default ];

  programs.roche-pi = {
    enable = true;
    stylix.enable = true;
  };
}
```

## Project shell usage

```nix
shellHook = ''
  ${inputs.roche-pi.lib.${system}.projectPiShellHook {
    agentTeam = "openai-only";
  }}
'';
```
```

- [ ] **Step 6: Verify the bare flake evaluates**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix flake show
```

Expected: command succeeds and shows at least `homeModules`, `packages`, or no outputs yet without syntax errors.

- [ ] **Step 7: Commit the bootstrap**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
git add flake.nix modules/parts.nix README.md package.json flake.lock
git commit -m "feat(flake): bootstrap dendritic pi config"
```

Expected: signed commit succeeds.

---

## Task 2: Copy current Pi resources into the new repo

**Files:**
- Create/copy: `/home/roche/projects/pi/roche-pi/resources/extensions/**`
- Create/copy: `/home/roche/projects/pi/roche-pi/resources/skills/**`
- Create/copy: `/home/roche/projects/pi/roche-pi/resources/agents/**`
- Create/copy: `/home/roche/projects/pi/roche-pi/resources/agent-teams/**`
- Create/copy: `/home/roche/projects/pi/roche-pi/resources/settings.json`
- Create/copy: `/home/roche/projects/pi/roche-pi/resources/pi-remote-package-lock.json`
- Create: `/home/roche/projects/pi/roche-pi/resources/themes/.gitkeep`
- Create: root symlinks `/home/roche/projects/pi/roche-pi/{extensions,skills,agents,agent-teams,themes}`

- [ ] **Step 1: Copy resource directories and files**

Run:

```bash
cd /home/roche/nixdots
mkdir -p /home/roche/projects/pi/roche-pi/resources
cp -R modules/home/desktop/utils/pi/extensions /home/roche/projects/pi/roche-pi/resources/extensions
cp -R modules/home/desktop/utils/pi/skills /home/roche/projects/pi/roche-pi/resources/skills
cp -R modules/home/desktop/utils/pi/agents /home/roche/projects/pi/roche-pi/resources/agents
cp -R modules/home/desktop/utils/pi/agent-teams /home/roche/projects/pi/roche-pi/resources/agent-teams
cp modules/home/desktop/utils/pi/settings.json /home/roche/projects/pi/roche-pi/resources/settings.json
cp modules/home/desktop/utils/pi/pi-remote-package-lock.json /home/roche/projects/pi/roche-pi/resources/pi-remote-package-lock.json
```

Expected: copied files appear under `/home/roche/projects/pi/roche-pi/resources`.

- [ ] **Step 2: Verify expected resource counts**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
find resources/extensions -type f | wc -l
find resources/skills -type f | wc -l
find resources/agents -type f | wc -l
find resources/agent-teams -type f | wc -l
jq . resources/settings.json >/dev/null
```

Expected: each `find` count is non-zero, and `jq` exits successfully.

- [ ] **Step 3: Add package-facing resource targets**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
mkdir -p resources/themes
: > resources/themes/.gitkeep
rm -rf resources/extensions/.pi resources/extensions/nobody-plans-for-pi
ln -sfn resources/extensions extensions
ln -sfn resources/skills skills
ln -sfn resources/agents agents
ln -sfn resources/agent-teams agent-teams
ln -sfn resources/themes themes
cat > .npmignore <<'EOF'
resources/extensions/**/*.test.ts
extensions/**/*.test.ts
EOF
```

Expected: root symlinks exist, `resources/themes/.gitkeep` is tracked, and extension tests are excluded from npm package payload.

- [ ] **Step 4: Commit resource import**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
git add .npmignore package.json resources extensions skills agents agent-teams themes
git commit -m "feat(resources): import pi configuration resources"
```

Expected: signed commit succeeds.

---

## Task 3: Extract package dependency derivations

**Files:**
- Create: `/home/roche/projects/pi/roche-pi/modules/packages/pi-remote.nix`
- Create: `/home/roche/projects/pi/roche-pi/modules/packages/notion-cli.nix`
- Create: `/home/roche/projects/pi/roche-pi/modules/packages/pi-deps.nix`

- [ ] **Step 1: Create `modules/packages/pi-remote.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/packages/pi-remote.nix`:

```nix
{ pkgs }:
let
  packageLock = ../../resources/pi-remote-package-lock.json;

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@noahsaso/pi-remote/-/pi-remote-0.3.1.tgz";
    hash = "sha256-d8tSk12rnZqHr2HDVnXclZBRPbqRPVft9CKYSdBJHr8=";
  };
in
pkgs.buildNpmPackage {
  pname = "pi-remote";
  version = "0.3.1";
  inherit src;

  npmDepsHash = "sha256-DucFlnKAAd8sFUptf5zapAXqYrf7OZn3/xNFHySAApc=";

  dontNpmBuild = true;
  makeCacheWritable = true;
  npmRebuildFlags = [ "node-pty" ];

  postPatch = ''
    cp ${packageLock} package-lock.json
    ${pkgs.nodejs}/bin/node <<'NODE'
    const fs = require("node:fs");
    const packagePath = "package.json";
    const packageJson = JSON.parse(fs.readFileSync(packagePath, "utf8"));
    delete packageJson.devDependencies;
    packageJson.scripts = {};
    fs.writeFileSync(packagePath, JSON.stringify(packageJson, null, 2));
    NODE
  '';
}
```

- [ ] **Step 2: Create `modules/packages/notion-cli.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/packages/notion-cli.nix`:

```nix
{ pkgs }:

pkgs.buildGoModule rec {
  pname = "notion-cli";
  version = "0.7.0";

  src = pkgs.fetchFromGitHub {
    owner = "4ier";
    repo = "notion-cli";
    rev = "v${version}";
    hash = "sha256-Wy3Xi40dsmk0igxsGiX7fqvgMVnuIcdNkOefUBAgy/I=";
  };

  vendorHash = "sha256-l+js7rA49aDVu6sHcuNDSv8R8E/Fi1J7yE17uaKHhjQ=";

  ldflags = [
    "-s"
    "-w"
    "-X github.com/4ier/notion-cli/cmd.Version=${version}"
  ];

  postInstall = ''
    if [ -e "$out/bin/notion-cli" ]; then
      mv "$out/bin/notion-cli" "$out/bin/notion"
    fi
  '';

  meta = {
    description = "Full-featured CLI for Notion";
    homepage = "https://github.com/4ier/notion-cli";
    license = pkgs.lib.licenses.mit;
    mainProgram = "notion";
  };
}
```

- [ ] **Step 3: Create `modules/packages/pi-deps.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/packages/pi-deps.nix` by extracting the package dependency definitions from current `modules/home/desktop/utils/pi/files.nix`. It must return an attrset with these names:

```nix
{
  pkgs,
  piRemote,
}:
let
  piListenSrc = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@codexstar/pi-listen/-/pi-listen-7.2.2.tgz";
    hash = "sha256-MbYQiwQMvXkN0dRYdMTTX+4whLjey/yGcke5zq6BRO0=";
  };

  sherpaOnnxNode = pkgs.fetchzip {
    url = "https://registry.npmjs.org/sherpa-onnx-node/-/sherpa-onnx-node-1.13.0.tgz";
    hash = "sha256-YV+px436CmhSDmshUmOLWTaeoqp+miY69TqHJpMwPkA=";
  };

  sherpaOnnxLinuxX64 = pkgs.fetchzip {
    url = "https://registry.npmjs.org/sherpa-onnx-linux-x64/-/sherpa-onnx-linux-x64-1.13.0.tgz";
    hash = "sha256-w1SfJmebP8inl1z/sd0qaC1wL/KYDmnzD/NiDCde3gY=";
  };

  piListen = pkgs.runCommand "pi-listen-7.2.2" { } ''
    mkdir -p $out/node_modules
    cp -r ${piListenSrc}/. $out/
    cp -r ${sherpaOnnxNode} $out/node_modules/sherpa-onnx-node
    cp -r ${sherpaOnnxLinuxX64} $out/node_modules/sherpa-onnx-linux-x64
  '';

  matrixSdkCryptoNodeFile = "matrix-sdk-crypto.linux-x64-gnu.node";

  matrixSdkCryptoNode = pkgs.fetchurl {
    url = "https://github.com/matrix-org/matrix-rust-sdk-crypto-nodejs/releases/download/v0.4.0/matrix-sdk-crypto.linux-x64-gnu.node";
    hash = "sha256-cHjU3ZhxKPea/RksT2IfZK3s435D8qh1bx0KnwNN5xg=";
  };

  piMessengerBridgePackageLock = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/tintinweb/pi-messenger-bridge/8b0c1da19c930225b15ec971f9225241a82b381d/package-lock.json";
    hash = "sha256-6gwABX5hgrLzHWLP/CWefq1F5pwuwlPTNoYi702R8pw=";
  };

  piMessengerBridgeSrc = pkgs.fetchzip {
    url = "https://registry.npmjs.org/pi-messenger-bridge/-/pi-messenger-bridge-0.4.0.tgz";
    hash = "sha256-sbI1Diu0Ii/zU9p5Ar0RnwQJ5hbr3BM1ShNNc85PFqs=";
  };

  piMessengerBridge = pkgs.buildNpmPackage {
    pname = "pi-messenger-bridge";
    version = "0.4.0";
    src = piMessengerBridgeSrc;

    npmDepsHash = "sha256-iTQy7wkXT86MZCDpPnU7jpwoxroV97w7WyxTqW15ZwI=";

    dontNpmBuild = true;
    makeCacheWritable = true;

    postPatch = ''
      cp ${piMessengerBridgePackageLock} package-lock.json
    '';

    postInstall = ''
      install -Dm444 ${matrixSdkCryptoNode} \
        $out/lib/node_modules/pi-messenger-bridge/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/${matrixSdkCryptoNodeFile}
    '';
  };

  piSubagentsSrc = pkgs.fetchgit {
    url = "https://github.com/nicobailon/pi-subagents.git";
    rev = "0b3f5b4d16557228cf7ce3e2de7b708f94ccf9ac";
    sha256 = "sha256-OOepzpERAz1E7yIl85IxcXs+QFUzi6uhpC6RjQXr1Yc=";
  };

  piSubagents = pkgs.buildNpmPackage {
    pname = "pi-subagents";
    version = "0.23.0";
    src = piSubagentsSrc;
    npmDepsHash = "sha256-hJwe6crzgVnosyJcfV5BIu0cfm69kEQ1vaZNteQxoY4=";
    dontNpmBuild = true;
  };

  superpowersSrc = pkgs.fetchgit {
    url = "https://github.com/obra/superpowers.git";
    rev = "e7a2d16476bf042e9add4699c9d018a90f86e4a6";
    sha256 = "sha256-8/M/S0BUYurZkFqe6LemVtBQnPSxBNfy1C7Q6f92hjE=";
  };

  diffPackageSrc = pkgs.fetchurl {
    url = "https://registry.npmjs.org/diff/-/diff-7.0.0.tgz";
    sha256 = "sha256-kRLnmAa9a+V4p6bxJNlnEdQGCwus1NS6xOlq59CPKsE=";
  };

  diffPackage = pkgs.runCommand "diff-npm" { } ''
    mkdir -p $out/lib/node_modules/diff
    cd $out/lib/node_modules/diff
    ${pkgs.gnutar}/bin/tar -xzf ${diffPackageSrc} --strip-components=1
  '';
in
{
  inherit
    diffPackage
    piListen
    piMessengerBridge
    piRemote
    piSubagents
    superpowersSrc
    ;

  packagePaths = [
    "${piListen}"
    "${piMessengerBridge}/lib/node_modules/pi-messenger-bridge"
    "${piRemote}/lib/node_modules/@noahsaso/pi-remote"
    "${piSubagents}/lib/node_modules/pi-subagents"
    "${superpowersSrc}"
  ];
}
```

- [ ] **Step 4: Format the new Nix files**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix fmt
```

Expected: command succeeds or reports no formatter configured. If no formatter exists yet, run `nixfmt-rfc-style modules/**/*.nix` after adding the formatter in Task 8.

- [ ] **Step 5: Commit extracted package derivations**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
git add modules/packages resources/pi-remote-package-lock.json
git commit -m "feat(packages): extract pi dependency derivations"
```

Expected: signed commit succeeds.

---

## Task 4: Implement settings and theme builders

**Files:**
- Create: `/home/roche/projects/pi/roche-pi/modules/lib/settings.nix`
- Create: `/home/roche/projects/pi/roche-pi/modules/lib/theme.nix`

- [ ] **Step 1: Create `modules/lib/theme.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/lib/theme.nix`:

```nix
{ }:

{
  mkStylixTheme = colors:
    let
      hex = color: "#${color}";
    in
    {
      "$schema" = "https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json";
      name = "stylix";
      vars = {
        base00 = hex colors.base00;
        base01 = hex colors.base01;
        base02 = hex colors.base02;
        base03 = hex colors.base03;
        base04 = hex colors.base04;
        base05 = hex colors.base05;
        base06 = hex colors.base06;
        base07 = hex colors.base07;
        base08 = hex colors.base08;
        base09 = hex colors.base09;
        base0A = hex colors.base0A;
        base0B = hex colors.base0B;
        base0C = hex colors.base0C;
        base0D = hex colors.base0D;
        base0E = hex colors.base0E;
        base0F = hex colors.base0F;
      };
      colors = {
        accent = "base0D";
        border = "base01";
        borderAccent = "base0D";
        borderMuted = "base02";
        success = "base0B";
        error = "base08";
        warning = "base0A";
        muted = "base04";
        dim = "base03";
        text = "base05";
        thinkingText = "base0C";
        selectedBg = "base02";
        userMessageBg = "base01";
        userMessageText = "base06";
        customMessageBg = "base00";
        customMessageText = "base05";
        customMessageLabel = "base0D";
        toolPendingBg = "base00";
        toolSuccessBg = "base00";
        toolErrorBg = "base00";
        toolTitle = "base0D";
        toolOutput = "base05";
        mdHeading = "base0A";
        mdLink = "base0D";
        mdLinkUrl = "base0C";
        mdCode = "base0B";
        mdCodeBlock = "base05";
        mdCodeBlockBorder = "base01";
        mdQuote = "base04";
        mdQuoteBorder = "base01";
        mdHr = "base01";
        mdListBullet = "base09";
        toolDiffAdded = "base0B";
        toolDiffRemoved = "base08";
        toolDiffContext = "base03";
        syntaxComment = "base03";
        syntaxKeyword = "base0E";
        syntaxFunction = "base0D";
        syntaxVariable = "base08";
        syntaxString = "base0B";
        syntaxNumber = "base09";
        syntaxType = "base0A";
        syntaxOperator = "base0C";
        syntaxPunctuation = "base04";
        thinkingOff = "base01";
        thinkingMinimal = "base04";
        thinkingLow = "base0D";
        thinkingMedium = "base0C";
        thinkingHigh = "base0A";
        thinkingXhigh = "base08";
        bashMode = "base09";
      };
      export = {
        pageBg = hex colors.base00;
        cardBg = hex colors.base01;
        infoBg = hex colors.base02;
      };
    };
}
```

- [ ] **Step 2: Create `modules/lib/settings.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/lib/settings.nix`:

```nix
{ lib }:

{
  mkSettings =
    {
      baseSettings,
      packagePaths ? [ ],
      extraPackages ? [ ],
      theme ? "stylix",
      settingsOverrides ? { },
      intervalsPackagePath ? null,
    }:
    let
      intervalPackages = lib.optionals (intervalsPackagePath != null) [ intervalsPackagePath ];
    in
    baseSettings
    // {
      inherit theme;
      packages = packagePaths ++ intervalPackages ++ extraPackages;
    }
    // settingsOverrides;
}
```

- [ ] **Step 3: Verify generated builders evaluate with `nix eval` after package module exists**

Run after Task 5 creates flake lib outputs:

```bash
cd /home/roche/projects/pi/roche-pi
nix eval .#lib.x86_64-linux --apply 'builtins.attrNames'
```

Expected: output includes `mkSettings`, `mkStylixTheme`, and `projectPiShellHook` after Task 7.

- [ ] **Step 4: Commit library builders**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
git add modules/lib/theme.nix modules/lib/settings.nix
git commit -m "feat(lib): add pi settings and theme builders"
```

Expected: signed commit succeeds.

---

## Task 5: Implement the `pi-config` package output

**Files:**
- Create: `/home/roche/projects/pi/roche-pi/modules/packages/pi-config.nix`

- [ ] **Step 1: Create `modules/packages/pi-config.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/packages/pi-config.nix`:

```nix
{ self, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      piRemote = import ./pi-remote.nix { inherit pkgs; };
      notionCli = import ./notion-cli.nix { inherit pkgs; };
      piDeps = import ./pi-deps.nix { inherit pkgs piRemote; };
      settingsLib = import ../lib/settings.nix { inherit (pkgs) lib; };
      themeLib = import ../lib/theme.nix { };

      baseSettings = builtins.fromJSON (builtins.readFile ../../resources/settings.json);

      fallbackColors = {
        base00 = "1d2021";
        base01 = "3c3836";
        base02 = "504945";
        base03 = "665c54";
        base04 = "bdae93";
        base05 = "d5c4a1";
        base06 = "ebdbb2";
        base07 = "fbf1c7";
        base08 = "fb4934";
        base09 = "fe8019";
        base0A = "fabd2f";
        base0B = "b8bb26";
        base0C = "8ec07c";
        base0D = "83a598";
        base0E = "d3869b";
        base0F = "d65d0e";
      };

      piSettings = settingsLib.mkSettings {
        inherit baseSettings;
        packagePaths = piDeps.packagePaths;
        theme = "stylix";
      };

      stylixPiTheme = themeLib.mkStylixTheme fallbackColors;

      piConfig = pkgs.runCommand "roche-pi-config" { } ''
        mkdir -p \
          $out/resources/extensions \
          $out/resources/skills \
          $out/resources/themes \
          $out/resources/agents \
          $out/resources/agent-teams \
          $out/node_modules

        cp ${../../package.json} $out/package.json
        cp ${../../.npmignore} $out/.npmignore
        cp -r ${../../resources/extensions}/. $out/resources/extensions/
        cp -r ${../../resources/skills}/. $out/resources/skills/
        cp -r ${../../resources/agents}/. $out/resources/agents/
        cp -r ${../../resources/agent-teams}/. $out/resources/agent-teams/
        cp -r ${../../resources/themes}/. $out/resources/themes/

        ln -s resources/extensions $out/extensions
        ln -s resources/skills $out/skills
        ln -s resources/agents $out/agents
        ln -s resources/agent-teams $out/agent-teams
        ln -s resources/themes $out/themes
        ln -s ${piDeps.diffPackage}/lib/node_modules/diff $out/node_modules/diff

        cat > $out/AGENTS.md <<'EOF'
        ## Plans, specs and designs

        - **Save plans to:** `docs/plans/YYYY-MM-DD-<feature-name>.md`
        - Write the validated design (spec) to `docs/specs/YYYY-MM-DD-<topic>-design.md`
        EOF

        printf '%s' ${pkgs.lib.escapeShellArg (builtins.toJSON piSettings)} > $out/settings.json
        printf '%s' ${pkgs.lib.escapeShellArg (builtins.toJSON stylixPiTheme)} > $out/themes/stylix.json
      '';
    in
    {
      packages = {
        default = piConfig;
        pi-config = piConfig;
        inherit notionCli piRemote;
      };

      lib = {
        inherit (settingsLib) mkSettings;
        inherit (themeLib) mkStylixTheme;
        piConfigPackage = piConfig;
      };

      checks.pi-config-build = piConfig;
    };
}
```

- [ ] **Step 2: Build `pi-config`**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix build .#packages.x86_64-linux.pi-config
```

Expected: `./result` points to a store path containing `settings.json`, `extensions`, `skills`, `agents`, and `agent-teams`.

- [ ] **Step 3: Inspect generated package contents**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
find result -maxdepth 2 -type f -o -type l | sort | head -80
jq . result/settings.json >/dev/null
jq . result/themes/stylix.json >/dev/null
```

Expected: `jq` succeeds and the file list includes package resources.

- [ ] **Step 4: Commit `pi-config` package**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
git add modules/packages/pi-config.nix
git commit -m "feat(packages): build pi config resource package"
```

Expected: signed commit succeeds.

---

## Task 6: Implement the Home Manager module

**Files:**
- Create: `/home/roche/projects/pi/roche-pi/modules/home/pi.nix`
- Create: `/home/roche/projects/pi/roche-pi/modules/home/jailed-pi.nix`

- [ ] **Step 1: Create `modules/home/pi.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/home/pi.nix`:

```nix
{ self, ... }:
{
  flake.homeModules.pi =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.roche-pi;
      piConfig = self.packages.${pkgs.system}.pi-config;
      themeLib = import ../lib/theme.nix { };

      stylixTheme = themeLib.mkStylixTheme config.lib.stylix.colors;

      baseSettings = builtins.fromJSON (builtins.readFile "${piConfig}/settings.json");
      settings = baseSettings // cfg.settings;

      intervalsExtensionSource =
        if cfg.intervals.package != null then
          "${cfg.intervals.package}/extensions/pi-intervals"
        else
          cfg.intervals.path;

      intervalsSkillSource =
        if cfg.intervals.package != null then
          "${cfg.intervals.package}/skills/intervals-time-entries"
        else
          "${cfg.intervals.path}/skills/intervals-time-entries";
    in
    {
      options.programs.roche-pi = {
        enable = lib.mkEnableOption "Roché's Pi configuration";

        package = lib.mkOption {
          type = lib.types.package;
          default = piConfig;
          description = "Store-backed Pi config package to install.";
        };

        installNotionCli = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Install the notion CLI used by the bundled Notion skill.";
        };

        settings = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Settings merged into ~/.pi/agent/settings.json.";
        };

        stylix.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Generate ~/.pi/agent/themes/stylix.json from Stylix colors.";
        };

        intervals = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Install local pi-intervals extension and skill symlinks.";
          };

          path = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Local path to the pi-intervals checkout.";
          };

          package = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            description = "Package containing pi-intervals resources.";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = (!cfg.intervals.enable) || cfg.intervals.path != null || cfg.intervals.package != null;
            message = "programs.roche-pi.intervals.enable requires either intervals.path or intervals.package.";
          }
        ];

        home.packages = lib.optional cfg.installNotionCli self.packages.${pkgs.system}.notion-cli;

        home.file = {
          ".pi/agent/AGENTS.md" = {
            force = true;
            source = "${cfg.package}/AGENTS.md";
          };

          ".pi/agent/settings.json" = {
            force = true;
            text = builtins.toJSON settings;
          };

          ".pi/agent/extensions".source = "${cfg.package}/extensions";
          ".pi/agent/agent-teams".source = "${cfg.package}/agent-teams";
          ".pi/agent/agents".source = "${cfg.package}/agents";
          ".pi/agent/skills".source = "${cfg.package}/skills";
          ".pi/agent/node_modules".source = "${cfg.package}/node_modules";

          ".pi/agent/themes/stylix.json" = lib.mkIf cfg.stylix.enable {
            force = true;
            text = builtins.toJSON stylixTheme;
          };

          ".pi/dashboard/config.json" = {
            force = true;
            text = builtins.toJSON {
              port = 18765;
              piPort = 18766;
              tunnel.enabled = false;
            };
          };

          ".pi/agent/extensions/pi-intervals" = lib.mkIf cfg.intervals.enable {
            source = intervalsExtensionSource;
          };

          ".pi/agent/skills/intervals-time-entries" = lib.mkIf cfg.intervals.enable {
            source = intervalsSkillSource;
          };
        };
      };
    };

  flake.homeModules.default = self.homeModules.pi;
}
```

- [ ] **Step 2: Create `modules/home/jailed-pi.nix` with an explicit unsupported-enable assertion**

Write `/home/roche/projects/pi/roche-pi/modules/home/jailed-pi.nix`:

```nix
{ ... }:
{
  flake.homeModules.jailed-pi =
    { config, lib, ... }:
    let
      cfg = config.programs.roche-pi.jailed;
    in
    {
      options.programs.roche-pi.jailed.enable = lib.mkEnableOption "jailed Pi integration";

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = false;
            message = "programs.roche-pi.jailed.enable is reserved for the follow-up jailed Pi migration.";
          }
        ];
      };
    };
}
```

- [ ] **Step 3: Evaluate Home Manager module output**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix eval .#homeModules --apply 'builtins.attrNames'
```

Expected: output contains `default`, `pi`, and `jailed-pi`.

- [ ] **Step 4: Commit Home Manager modules**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
git add modules/home
git commit -m "feat(home): add roche pi home module"
```

Expected: signed commit succeeds.

---

## Task 7: Implement project/devenv helper and dev shell

**Files:**
- Create: `/home/roche/projects/pi/roche-pi/modules/lib/project-pi.nix`
- Create: `/home/roche/projects/pi/roche-pi/modules/devshells/default.nix`

- [ ] **Step 1: Create `modules/lib/project-pi.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/lib/project-pi.nix`:

```nix
{ self, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      piConfigPackage = self.packages.${system}.pi-config;

      projectPiShellHook =
        {
          agentTeam ? null,
          extraSettings ? { },
        }:
        let
          settings = {
            packages = [ "${piConfigPackage}" ];
          }
          // pkgs.lib.optionalAttrs (agentTeam != null) {
            activeAgentTeam = agentTeam;
          }
          // extraSettings;
        in
        ''
          mkdir -p .pi
          ln -sfn ${piConfigPackage}/agents .pi/agents
          ln -sfn ${piConfigPackage}/agent-teams .pi/agent-teams
          cat > .pi/settings.json <<'JSON'
          ${builtins.toJSON settings}
          JSON
        '';
    in
    {
      lib.projectPiShellHook = projectPiShellHook;
    };
}
```

- [ ] **Step 2: Create `modules/devshells/default.nix`**

Write `/home/roche/projects/pi/roche-pi/modules/devshells/default.nix`:

```nix
{ inputs, ... }:
{
  perSystem =
    { config, pkgs, system, ... }:
    {
      devShells.default = pkgs.mkShell {
        packages = [
          inputs.llm-agents.packages.${system}.pi
          pkgs.git
          pkgs.jq
          pkgs.nixfmt-rfc-style
        ];

        shellHook = ''
          ${config.lib.projectPiShellHook { agentTeam = "openai-only"; }}
        '';
      };

      formatter = pkgs.nixfmt-rfc-style;
    };
}
```

- [ ] **Step 3: Verify the helper output**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix develop --command bash -lc 'test -f .pi/settings.json && jq . .pi/settings.json && test -L .pi/agents && test -L .pi/agent-teams'
```

Expected: command succeeds and prints valid JSON containing the `pi-config` package path.

- [ ] **Step 4: Commit project helper**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
git add modules/lib/project-pi.nix modules/devshells/default.nix
git commit -m "feat(lib): add project pi shell helper"
```

Expected: signed commit succeeds.

---

## Task 8: Add checks and verify extracted repo

**Files:**
- Modify: `/home/roche/projects/pi/roche-pi/modules/packages/pi-config.nix`
- Modify: `/home/roche/projects/pi/roche-pi/modules/devshells/default.nix`

- [ ] **Step 1: Run formatter**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix fmt
```

Expected: command succeeds and formats Nix files.

- [ ] **Step 2: Build all key packages**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix build .#packages.x86_64-linux.pi-config
nix build .#packages.x86_64-linux.pi-remote
nix build .#packages.x86_64-linux.notion-cli
```

Expected: all builds succeed.

- [ ] **Step 3: Run flake check**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix flake check
```

Expected: command succeeds.

- [ ] **Step 4: Commit verification adjustments if any were needed**

Run only if files changed:

```bash
cd /home/roche/projects/pi/roche-pi
git status --short
git add modules
git commit -m "chore(flake): add verification checks"
```

Expected: signed commit succeeds if there were changes; skip if `git status --short` is empty.

---

## Task 9: Wire `nixdots` to the extracted flake

**Files:**
- Modify: `/home/roche/nixdots/flake.nix`
- Modify: `/home/roche/nixdots/modules/home/desktop/utils/pi/default.nix`

- [ ] **Step 1: Choose the `roche-pi` input source**

For local validation before the new repo is pushed, add this temporary input near the other personal inputs in `/home/roche/nixdots/flake.nix`:

```nix
    # Personal Pi configuration package
    roche-pi = {
      url = "path:/home/roche/projects/pi/roche-pi";
      inputs.nixpkgs.follows = "nixpkgs";
    };
```

For the final committed integration after the new repo is pushed, prefer:

```nix
    # Personal Pi configuration package
    roche-pi = {
      url = "github:rochecompaan/roche-pi";
      inputs.nixpkgs.follows = "nixpkgs";
    };
```

Do not commit the `github:` form until the remote repository exists and contains the commits being referenced. Use the `path:` form only as an explicit local-validation step.

- [ ] **Step 2: Replace `modules/home/desktop/utils/pi/default.nix`**

Replace `/home/roche/nixdots/modules/home/desktop/utils/pi/default.nix` with:

```nix
{ config, inputs, ... }:
{
  imports = [ inputs.roche-pi.homeModules.default ];

  programs.roche-pi = {
    enable = true;
    stylix.enable = true;

    intervals = {
      enable = true;
      path = "${config.home.homeDirectory}/projects/pi/extensions/pi-intervals";
    };

    settings = {
      defaultProvider = "openai-codex";
      defaultModel = "gpt-5.5";
      defaultThinkingLevel = "high";
    };
  };
}
```

- [ ] **Step 3: Update the lock file**

Run:

```bash
cd /home/roche/nixdots
nix flake lock --update-input roche-pi
```

Expected: `flake.lock` gains a local path input for `roche-pi`.

- [ ] **Step 4: Evaluate one Home Manager activation package**

Run:

```bash
cd /home/roche/nixdots
nix build .#homeConfigurations."roche@kipchoge".activationPackage
```

Expected: build succeeds.

- [ ] **Step 5: Commit `nixdots` integration**

Run:

```bash
cd /home/roche/nixdots
git add flake.nix flake.lock modules/home/desktop/utils/pi/default.nix
git commit -m "feat(pi): consume dendritic pi config flake"
```

Expected: signed commit succeeds.

---

## Task 10: Decide what to do with old local Pi files

**Files:**
- Modify/delete after confirmation: `/home/roche/nixdots/modules/home/desktop/utils/pi/**`
- Modify after confirmation: `/home/roche/nixdots/modules/home/desktop/utils/jailed-agents/default.nix`

- [ ] **Step 1: Check remaining references to old local files**

Run:

```bash
cd /home/roche/nixdots
rg -n "../pi/files.nix|utils/pi/files.nix|modules/home/desktop/utils/pi/(files|theme|pi-remote|notion-cli)|piFiles" modules home hosts flake.nix
```

Expected: remaining references are only in `jailed-agents/default.nix` and old files themselves.

- [ ] **Step 2: If jailed Pi still imports `../pi/files.nix`, postpone deletion**

If this command shows the jailed-agents import:

```bash
rg -n "import ../pi/files.nix" modules/home/desktop/utils/jailed-agents/default.nix
```

Expected: keep `modules/home/desktop/utils/pi/files.nix` and related package files until the jailed module is migrated in a separate follow-up change.

- [ ] **Step 3: Commit a cleanup only after jailed references are resolved**

Run only after a separate jailed migration removes all local imports:

```bash
cd /home/roche/nixdots
git rm -r modules/home/desktop/utils/pi/agents modules/home/desktop/utils/pi/agent-teams modules/home/desktop/utils/pi/extensions modules/home/desktop/utils/pi/skills
git commit -m "refactor(pi): remove local resource copies"
```

Expected: skip this commit during the first pass if jailed Pi still needs local files.

---

## Task 11: Final verification and handoff

**Files:**
- No planned file changes unless verification exposes a defect.

- [ ] **Step 1: Verify extracted repo is clean and passing**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
git status --short
nix flake check
```

Expected: `git status --short` is empty and `nix flake check` succeeds.

- [ ] **Step 2: Verify `nixdots` is clean and passing**

Run:

```bash
cd /home/roche/nixdots
git status --short
nix build .#homeConfigurations."roche@kipchoge".activationPackage
```

Expected: `git status --short` is empty and the build succeeds.

- [ ] **Step 3: Manually inspect generated Pi settings from the built package**

Run:

```bash
cd /home/roche/projects/pi/roche-pi
nix build .#packages.x86_64-linux.pi-config --no-link --print-out-paths | xargs -I{} jq '.packages' {}/settings.json
```

Expected: JSON array contains Nix store paths for `pi-listen`, `pi-messenger-bridge`, `pi-remote`, `pi-subagents`, and `superpowers`.

- [ ] **Step 4: Summarize remaining follow-up work**

Create a short note in the final response listing deferred items:

```text
Deferred:
- migrate jailed Pi to roche-pi.homeModules.jailed-pi
- convert nixdots roche-pi input from path: to github: after pushing the new repo
- add platform gates before enabling non-x86_64-linux systems
- optionally publish as an npm Pi package
```

Expected: user knows what is complete and what remains.
