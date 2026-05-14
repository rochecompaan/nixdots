# Jailed Pi Replacement Design

## Goal

Replace the local `jailed-pi` implementation in nixdots with the jailed Pi support provided by the `roche-pi` flake.

## Architecture

The existing unjailed Pi integration already imports `inputs.roche-pi.homeModules.default` from `modules/home/desktop/utils/pi/default.nix`. The jailed integration will use the Roche Pi jailed Home Manager module from `modules/home/desktop/utils/jailed-agents/default.nix` and configure `programs.roche-pi.jailed` instead of constructing a local `jail-nix` wrapper. The module source is imported with Home Manager DAG helpers available so its activation entry evaluates correctly in this repo.

The local module remains responsible only for nixdots-specific wiring: declaring the `openrouter-api-key` sops secret and passing its file path into `programs.roche-pi.jailed.apiKeys`. The shared Roche Pi module owns jailed agent directory activation, runtime wrapper generation, API key forwarding, git identity handling, and jail permissions.

## Files

- `modules/home/desktop/utils/jailed-agents/default.nix`: replace the hand-rolled jail implementation with Roche Pi jailed module configuration.
- `flake.nix`: make `inputs.roche-pi.inputs.jail-nix` follow the repo-level `jail-nix` input to avoid duplicate jail library locks.
- `flake.lock`: refresh after the input follow change.

## Behavior

The resulting `jailed-pi` executable should keep the current local behavior:

- use the normal Roche Pi agent config package and jailed agent directory managed by `roche-pi`;
- read `OPENROUTER_API_KEY` from the existing sops secret file;
- include `neovim` in the jailed runtime;
- preserve the unjailed Pi configuration in `modules/home/desktop/utils/pi/default.nix` unchanged.

## Verification

Run Nix formatting/checks for the changed files and evaluate the affected Home Manager configuration. If full Home Manager evaluation is too slow or blocked by external inputs, report the exact command and failure.
