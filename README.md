## Overview

Welcome to my Nix config!

- NixOS hosts are defined in `hosts/` and composed from shared modules in
  `modules/nixos`.
- Home Manager configs live in `home/` and compose shared modules in
  `modules/home` (including desktop-specific pieces under `modules/home/desktop`).

## Layout

- `flake.nix`: Wires `hosts/` and `home/` via flake-parts and exposes
  `nixosConfigurations` and `homeConfigurations`.
- `hosts/`: One folder per host with a `default.nix` plus hardware definitions.
- `modules/nixos/`: Shared NixOS modules
  - `core/`: Base system modules (boot, nix, networking, users, etc.).
  - `opt/`: Feature toggles and optional stacks (fonts, vpn, desktop, etc.).
- `home/`: Home Manager configs per user/host (e.g. `home/roche/kiptum.nix`).
- `modules/home/`: Shared Home Manager modules
  - `core/`: Base HM config, overlays, programs, and theming via Stylix.
  - `desktop/`: Desktop stack (WM, services, shell/term, utilities, options).
- `scripts/`: Helper scripts (e.g. `scripts/deploy-nixos.sh`).

## NixOS Composition

- All hosts import a shared base defined by `modules/nixos/default.nix`, which
  includes:
  - `modules/nixos/core/default.nix`: Core modules
  - `modules/nixos/opt/default.nix`: Optional/feature modules
- Feature flags are declared in `modules/nixos/opt/options.nix` and consumed by
  host configs. Typical host toggles:

  Example (hosts/kiptum/default.nix):

  - `fonts.enable = true`
  - `wayland.enable = true`
  - `pipewire.enable = true`
  - `desktop = { enable = true; de = "niri"; }`

- Each host adds its own imports and overrides under `hosts/<name>/default.nix`
  (hardware, Home Manager NixOS module, vendor-specific modules, etc.).

- Hosts are registered in `hosts/default.nix` where a helper `mkHost` composes
  `nixosConfigurations.<host>` by stacking the shared modules with the
  host’s folder. External modules such as `openziti-nix` and `disko` are added
  to all hosts here.

## Home Manager Composition

- Shared HM base lives in `modules/home/core/default.nix` and sets common
  environment, overlays, and theming glue. HM is enabled here.
- Desktop stack and options live under `modules/home/desktop/`:
  - `options.nix` exposes `default.de`, `default.terminal`, `default.browser`.
  - Submodules configure the selected WM (Hyprland/Niri), services and tools.
- Per-host Home configs live in `home/roche/<hostname>.nix` and typically:

  - Import Stylix and `modules/home` (+ `modules/home/desktop`).
  - Select desktop and terminal via `default.de` and `default.terminal`.
  - Add host-specific tweaks (e.g. monitors/workspaces for Hyprland, Niri KDL
    snippets).

  Examples:

  - `home/roche/kiptum.nix`: Sets `default.de = "niri"`, tweaks Niri outputs.
  - `home/roche/kipchoge.nix`: Sets `default.de = "hyprland"`, dual-4k layout.

## Add a New Host

1. Create `hosts/<name>/default.nix` (and `hardware-configuration.nix`). Import
   any needed modules (HM’s NixOS module, nixos-hardware, etc.) and set feature
   flags and desktop selection, e.g.:

- `networking.hostName = "<name>"`
- `fonts.enable = true`
- `wayland.enable = true`
- `pipewire.enable = true`
- `desktop = { enable = true; de = "hyprland"; }`

2. Register the host in `hosts/default.nix` by adding it to the
   `nixosConfigurations` set via `mkHost "<name>"`.

3. Optionally add it to `deploy.nodes` when using deploy-rs for homelab and
   remote hosts.

## Add Home Manager for a Host

1. Create `home/roche/<name>.nix` with imports and choices, e.g.:

- `imports = [ inputs.stylix.homeModules.stylix ../../modules/home ../../modules/home/desktop ]`
- `theme = "gruvbox"`
- `default = { de = "hyprland"; terminal = "kitty"; }`

2. Register it in `home/default.nix`:

- `"roche@<name>" = mkHome "<name>";`

3. Add any WM-specific tweaks in that file (Hyprland `monitor/workspace`, Niri
   `xdg.configFile."niri/config.kdl".text = lib.mkAfter '' ... ''`).

## Notes

My config started as a fork of [elythh/flake](https://github.com/elythh/flake).
Thank you elythh for the inpsiration!
