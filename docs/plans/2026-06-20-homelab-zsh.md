# Homelab zsh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Roché's existing Home Manager zsh experience to homelab/server NixOS hosts without changing desktop Home Manager ownership.

**Architecture:** Extract the zsh Home Manager module into a shared non-desktop module, then add a lightweight homelab Home Manager profile for `roche`. Wire that profile only into homelab NixOS hosts via the Home Manager NixOS module, leaving desktop hosts on standalone `homeConfigurations`.

**Tech Stack:** Nix flakes, NixOS modules, Home Manager, zsh, zplug, Atuin, Starship.

---

## File Structure

- `modules/home/shell/default.nix`: New shared Home Manager shell entrypoint; imports shared zsh.
- `modules/home/shell/zsh/default.nix`: Moved shared zsh module; owns zsh, aliases, plugins, Atuin, Starship, and the `nvim` wrapper.
- `modules/home/shell/zsh/run-as-service.nix`: Moved helper package used by the shared zsh module.
- `modules/home/desktop/shell/default.nix`: Desktop shell aggregator; imports shared shell plus desktop-only `zellij` and `fish` modules.
- `home/roche/homelab.nix`: New lightweight Home Manager profile for the homelab `roche` user.
- `modules/nixos/opt/homelab-home/default.nix`: New NixOS module that imports Home Manager and attaches `home/roche/homelab.nix` to `roche`.
- `hosts/default.nix`: Wires the homelab Home Manager module into only `dauwalter`, `kipsang`, `fordyce`, `selassie`, and `walmsley`.

## Testing Strategy

This is Nix configuration work. Do not add a new automated test suite for static config. Use Nix parsing, eval, flake, and host build commands as the verification gates. Because new files referenced by a flake are ignored until staged, stage new files before normal `nix eval`, `nix flake check`, or `nix build` commands.

---

### Task 1: Extract zsh into a shared Home Manager shell module

**Files:**
- Create: `modules/home/shell/default.nix`
- Move: `modules/home/desktop/shell/zsh/default.nix` -> `modules/home/shell/zsh/default.nix`
- Move: `modules/home/desktop/shell/zsh/run-as-service.nix` -> `modules/home/shell/zsh/run-as-service.nix`
- Modify: `modules/home/desktop/shell/default.nix`

- [ ] **Step 1: Verify the shared zsh module does not exist yet**

Run:

```bash
test -f modules/home/shell/zsh/default.nix
```

Expected: command exits non-zero because the shared module has not been created yet.

- [ ] **Step 2: Move the existing desktop zsh module into the shared shell tree**

Run:

```bash
mkdir -p modules/home/shell
git mv modules/home/desktop/shell/zsh modules/home/shell/zsh
```

Expected: `modules/home/shell/zsh/default.nix` and `modules/home/shell/zsh/run-as-service.nix` now exist, and `modules/home/desktop/shell/zsh/` is removed.

- [ ] **Step 3: Create the shared shell entrypoint**

Create `modules/home/shell/default.nix` with:

```nix
{
  imports = [
    ./zsh
  ];
}
```

- [ ] **Step 4: Keep desktop shell imports working through the shared shell module**

Replace `modules/home/desktop/shell/default.nix` with:

```nix
{
  imports = [
    ../../shell
    ./zellij
    ./fish
  ];
}
```

- [ ] **Step 5: Add deterministic Starship color fallbacks to the shared zsh module**

In `modules/home/shell/zsh/default.nix`, replace the top-level file shape from:

```nix
{
  config,
  pkgs,
  lib,
  ...
}:
{
```

with:

```nix
{
  config,
  pkgs,
  lib,
  ...
}:
let
  stylixColors = config.lib.stylix.colors or { };
  colors = {
    base01 = stylixColors.base01 or "1e1e2e";
    base03 = stylixColors.base03 or "45475a";
    base05 = stylixColors.base05 or "cdd6f4";
    base08 = stylixColors.base08 or "f38ba8";
    base09 = stylixColors.base09 or "fab387";
    base0C = stylixColors.base0C or "94e2d5";
    base0D = stylixColors.base0D or "89b4fa";
  };
in
{
```

Then replace this Starship opening:

```nix
  programs.starship = with config.lib.stylix.colors; {
    enable = true;
    settings = {
```

with:

```nix
  programs.starship = {
    enable = true;
    settings = with colors; {
```

Expected: desktop profiles still use Stylix colors, while homelab profiles can evaluate without importing Stylix.

- [ ] **Step 6: Make shell startup safe when optional commands are unavailable**

In `modules/home/shell/zsh/default.nix`, replace the first lines of `programs.zsh.initContent` with:

```nix
    initContent = ''
      PROMPT_EOL_MARK=""
      if command -v kubectl >/dev/null 2>&1; then
        source <(kubectl completion zsh)
      fi
      if command -v zoxide >/dev/null 2>&1; then
        eval "$(zoxide init zsh)"
      fi
```

Inside the `kn()` function in the same string, insert this guard immediately after the usage check and before `kubectl get namespace`:

```zsh
        command -v kubectl >/dev/null 2>&1 || {
          echo "kubectl not found" >&2
          return 1
        }
```

Expected: interactive shells do not print startup errors if `kubectl` or `zoxide` is missing from PATH.

- [ ] **Step 7: Align the `ls` alias with the packaged binary name**

In `modules/home/shell/zsh/default.nix`, replace:

```nix
      ls = "exa";
```

with:

```nix
      ls = "eza";
```

Expected: the alias uses the maintained `eza` binary that is packaged for both desktop and homelab profiles.

- [ ] **Step 8: Make the `nvim` wrapper work with standalone and NixOS-module Home Manager profiles**

In `modules/home/shell/zsh/default.nix`, replace the `home.file.".local/bin/nvim".text` string with:

```nix
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail
      NV_DIR="''${XDG_RUNTIME_DIR:-/tmp}"
      mkdir -p "''${NV_DIR}"
      NVIM_LISTEN_ADDRESS="$(mktemp -u "''${NV_DIR}/nvim-''${USER}-XXXXXX.sock")"
      export NVIM_LISTEN_ADDRESS

      candidates=(
        "$HOME/.nix-profile/bin/nvim"
        "/etc/profiles/per-user/''${USER}/bin/nvim"
        "/run/current-system/sw/bin/nvim"
      )

      for candidate in "''${candidates[@]}"; do
        if [ -x "''${candidate}" ]; then
          exec -a nvim "''${candidate}" --listen "''${NVIM_LISTEN_ADDRESS}" "$@"
        fi
      done

      echo "nvim executable not found; install neovim or nixvim" >&2
      exit 127
    '';
```

Expected: desktop standalone Home Manager keeps using `$HOME/.nix-profile/bin/nvim`, while homelab NixOS-module Home Manager can use `/etc/profiles/per-user/roche/bin/nvim`.

- [ ] **Step 9: Stage the moved and new files before flake evaluation**

Run:

```bash
git add modules/home/desktop/shell/default.nix modules/home/shell
```

Expected: the new shared module path is visible to flake-based eval commands.

- [ ] **Step 10: Verify desktop Home Manager still evaluates with shared zsh**

Run:

```bash
nix eval '.#homeConfigurations."roche@kiptum".config.programs.zsh.shellAliases.ls'
nix eval '.#homeConfigurations."roche@kipchoge".config.programs.zsh.enable'
```

Expected:

```text
"eza"
true
```

- [ ] **Step 11: Commit the shared shell extraction**

Run:

```bash
git status --short
git commit -m "refactor(shell): share zsh home module"
```

Expected: commit includes only `modules/home/desktop/shell/default.nix` and files under `modules/home/shell/`.

---

### Task 2: Add the lightweight homelab Home Manager profile

**Files:**
- Create: `home/roche/homelab.nix`
- Create: `modules/nixos/opt/homelab-home/default.nix`

- [ ] **Step 1: Verify homelab NixOS hosts do not expose Home Manager user config yet**

Run:

```bash
nix eval '.#nixosConfigurations.dauwalter.config.home-manager.users.roche.home.username'
```

Expected: command exits non-zero because the Home Manager NixOS module is not imported for `dauwalter` yet.

- [ ] **Step 2: Create the homelab Home Manager profile**

Create `home/roche/homelab.nix` with:

```nix
{ pkgs, ... }:
{
  imports = [
    ../../modules/home/shell
  ];

  home = {
    username = "roche";
    homeDirectory = "/home/roche";
    stateVersion = "24.05";

    sessionVariables = {
      EDITOR = "nvim";
      PAGER = "less";
      MANPAGER = "nvim +Man!";
      MANWIDTH = "999";
    };

    packages = with pkgs; [
      atuin
      bat
      curl
      eza
      fzf
      git
      gnugrep
      gnupg
      jq
      kubectl
      kubectx
      lazygit
      less
      neovim
      openssh
      starship
      timewarrior
      zoxide
    ];
  };

  programs.home-manager.enable = true;
}
```

Expected: the profile imports only the shared shell module and CLI packages, not `../../modules/home` or `../../modules/home/desktop`.

- [ ] **Step 3: Create the homelab NixOS Home Manager bridge module**

Create `modules/nixos/opt/homelab-home/default.nix` with:

```nix
{ inputs, self, ... }:
{
  imports = [
    inputs.hm.nixosModules.home-manager
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = {
      inherit inputs self;
    };
    users.roche = import ../../../../home/roche/homelab.nix;
  };
}
```

Expected: the module configures Home Manager only when imported by a host.

- [ ] **Step 4: Stage new files before parse checks**

Run:

```bash
git add home/roche/homelab.nix modules/nixos/opt/homelab-home/default.nix
```

Expected: both new files are staged.

- [ ] **Step 5: Parse the new Nix files**

Run:

```bash
nix-instantiate --parse home/roche/homelab.nix >/dev/null
nix-instantiate --parse modules/nixos/opt/homelab-home/default.nix >/dev/null
```

Expected: both commands exit 0.

- [ ] **Step 6: Commit the homelab profile and bridge module**

Run:

```bash
git status --short
git commit -m "feat(home): add homelab shell profile"
```

Expected: commit includes only `home/roche/homelab.nix` and `modules/nixos/opt/homelab-home/default.nix`.

---

### Task 3: Wire the homelab profile into server hosts only

**Files:**
- Modify: `hosts/default.nix`

- [ ] **Step 1: Replace the `mkHost` helper and host registrations**

In `hosts/default.nix`, replace the current `nixosConfigurations` `let` block and host attribute set with:

```nix
    nixosConfigurations =
      let
        inherit (inputs.nixpkgs.lib) nixosSystem optional;
        inherit (import "${self}/modules/nixos") default;

        specialArgs = {
          inherit inputs self;
        };

        mkHost =
          {
            hostname,
            homelabHome ? false,
          }:
          nixosSystem {
            inherit specialArgs;
            modules =
              default
              ++ [
                # Provide openziti overlay + modules to all hosts
                inputs.openziti-nix.nixosModules.default
                inputs.disko.nixosModules.disko
              ]
              ++ optional homelabHome ../modules/nixos/opt/homelab-home
              ++ [
                ./${hostname}
              ];
          };
      in
      {
        kiptum = mkHost { hostname = "kiptum"; };
        kipchoge = mkHost { hostname = "kipchoge"; };
        dauwalter = mkHost {
          hostname = "dauwalter";
          homelabHome = true;
        };
        kipsang = mkHost {
          hostname = "kipsang";
          homelabHome = true;
        };
        fordyce = mkHost {
          hostname = "fordyce";
          homelabHome = true;
        };
        selassie = mkHost {
          hostname = "selassie";
          homelabHome = true;
        };
        walmsley = mkHost {
          hostname = "walmsley";
          homelabHome = true;
        };
      };
```

Expected: only the five homelab hosts set `homelabHome = true`; `kiptum` and `kipchoge` do not.

- [ ] **Step 2: Stage the host wiring before flake evaluation**

Run:

```bash
git add hosts/default.nix
```

Expected: the modified host wiring is staged.

- [ ] **Step 3: Verify each homelab host exposes the Home Manager user profile**

Run:

```bash
for host in dauwalter kipsang fordyce selassie walmsley; do
  printf '%s ' "$host"
  nix eval ".#nixosConfigurations.${host}.config.home-manager.users.roche.home.username"
done
```

Expected:

```text
dauwalter "roche"
kipsang "roche"
fordyce "roche"
selassie "roche"
walmsley "roche"
```

- [ ] **Step 4: Verify desktop NixOS hosts are not managed by the NixOS Home Manager module**

Run:

```bash
for host in kiptum kipchoge; do
  if nix eval ".#nixosConfigurations.${host}.config.home-manager.users.roche.home.username" >/dev/null 2>&1; then
    echo "unexpected Home Manager NixOS profile on ${host}" >&2
    exit 1
  else
    echo "${host}: no NixOS Home Manager profile, as expected"
  fi
done
```

Expected:

```text
kiptum: no NixOS Home Manager profile, as expected
kipchoge: no NixOS Home Manager profile, as expected
```

- [ ] **Step 5: Commit the host wiring**

Run:

```bash
git status --short
git commit -m "feat(nixos): enable homelab zsh profile"
```

Expected: commit includes only `hosts/default.nix`.

---

### Task 4: Final verification

**Files:**
- No new files.
- Verification covers all files changed in Tasks 1-3.

- [ ] **Step 1: Format the Nix files**

Run:

```bash
nix fmt
```

Expected: formatter exits 0. If it changes files, review `git diff`, stage the formatting changes, and amend the relevant previous commit with `git commit --amend --no-edit`.

- [ ] **Step 2: Run the full flake check**

Run:

```bash
nix flake check
```

Expected: output ends with `all checks passed!`.

- [ ] **Step 3: Build all affected homelab NixOS systems**

Run:

```bash
for host in dauwalter kipsang fordyce selassie walmsley; do
  nix build ".#nixosConfigurations.${host}.config.system.build.toplevel" --no-link
done
```

Expected: all five builds exit 0.

- [ ] **Step 4: Build desktop standalone Home Manager activation packages**

Run:

```bash
nix build '.#homeConfigurations."roche@kiptum".activationPackage' --no-link
nix build '.#homeConfigurations."roche@kipchoge".activationPackage' --no-link
```

Expected: both builds exit 0.

- [ ] **Step 5: Confirm the worktree is clean after verification**

Run:

```bash
git status --short
```

Expected: no output.

- [ ] **Step 6: Report verification evidence**

In the final handoff, include:

```text
Verified:
- nix fmt
- nix flake check
- nix build .#nixosConfigurations.{dauwalter,kipsang,fordyce,selassie,walmsley}.config.system.build.toplevel --no-link
- nix build .#homeConfigurations."roche@kiptum".activationPackage --no-link
- nix build .#homeConfigurations."roche@kipchoge".activationPackage --no-link
```
