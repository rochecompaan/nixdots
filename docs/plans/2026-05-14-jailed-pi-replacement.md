# Jailed Pi Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace nixdots' local jailed Pi wrapper with the jailed Pi Home Manager module from `roche-pi`.

**Architecture:** Keep unjailed Pi configuration in `modules/home/desktop/utils/pi/default.nix`. Convert `modules/home/desktop/utils/jailed-agents/default.nix` into a small adapter that imports the Roche Pi jailed module source with Home Manager DAG helpers, declares the local sops secret, and configures `programs.roche-pi.jailed`.

**Tech Stack:** Nix flakes, Home Manager modules, sops-nix, Roche Pi flake, jail-nix.

---

### Task 1: Replace local jailed-pi module

**Files:**
- Modify: `modules/home/desktop/utils/jailed-agents/default.nix`

- [ ] **Step 1: Capture current references**

Run: `rg -n "jailed-pi|programs\.roche-pi\.jailed|openrouter-api-key" modules/home/desktop/utils flake.nix`

Expected: output includes the current local jail implementation and no existing `programs.roche-pi.jailed` configuration.

- [ ] **Step 2: Replace module contents**

Write this exact module to `modules/home/desktop/utils/jailed-agents/default.nix`:

```nix
{
  config,
  inputs,
  pkgs,
  ...
}:
let
  # Import the Roche Pi jailed module with Home Manager's DAG helpers.
  rochePiJailedModule =
    (import "${inputs.roche-pi}/modules/home/jailed-pi.nix" {
      self = inputs.roche-pi;
      lib = inputs.nixpkgs.lib // {
        hm = inputs.hm.lib.hm;
      };
    }).flake.homeModules."jailed-pi";
in
{
  imports = [ rochePiJailedModule ];

  sops.secrets."openrouter-api-key" = {
    sopsFile = "${inputs.nix-secrets}/secrets.yaml";
  };

  programs.roche-pi.jailed = {
    enable = true;
    apiKeys.OPENROUTER_API_KEY.file = config.sops.secrets."openrouter-api-key".path;
    extraPkgs = [ pkgs.neovim ];
  };
}
```

- [ ] **Step 3: Format the module**

Run: `nix fmt modules/home/desktop/utils/jailed-agents/default.nix`

Expected: command exits successfully.

### Task 2: Make roche-pi share the repo jail-nix input

**Files:**
- Modify: `flake.nix`
- Modify: `flake.lock`

- [ ] **Step 1: Add input follow**

In the `roche-pi` input block in `flake.nix`, add:

```nix
      inputs.jail-nix.follows = "jail-nix";
```

between the existing `inputs.home-manager.follows = "hm";` and `inputs.llm-agents.follows = "llm-agents";` lines.

- [ ] **Step 2: Refresh the lock file**

Run: `nix flake lock --update-input roche-pi`

Expected: lock refreshes successfully and `roche-pi.inputs.jail-nix` follows the top-level `jail-nix` input instead of creating `jail-nix_2`.

### Task 3: Verify the replacement

**Files:**
- Check: `modules/home/desktop/utils/jailed-agents/default.nix`
- Check: `flake.nix`
- Check: `flake.lock`

- [ ] **Step 1: Inspect the diff**

Run: `git diff -- modules/home/desktop/utils/jailed-agents/default.nix flake.nix flake.lock`

Expected: the jailed-agents module is much smaller, `flake.nix` has the new follow, and `flake.lock` no longer adds a duplicate jail-nix input.

- [ ] **Step 2: Run focused flake evaluation**

Run: `nix build .#homeConfigurations."roche@biko".activationPackage --dry-run`

Expected: evaluation succeeds or reaches only normal build/download planning. If the host attribute differs, list available `homeConfigurations` and run the matching Roche desktop profile.

- [ ] **Step 3: Run repository formatter/check if practical**

Run: `nix fmt`

Expected: command exits successfully.
