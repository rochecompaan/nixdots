# Homelab zsh Home Manager Design

## Summary

Add Roché's existing Home Manager zsh experience to homelab/server NixOS hosts without moving desktop Home Manager management into NixOS. Desktop hosts keep their current standalone `homeConfigurations`; homelab hosts receive a lightweight Home Manager profile during `nixos-rebuild`.

## Goals

- Reuse the current zsh, aliases, completions, Atuin, Starship, and helper-script configuration for server logins.
- Keep homelab/server hosts lightweight by avoiding the full desktop Home Manager module stack and GUI package set.
- Keep desktop hosts (`kiptum`, `kipchoge`) on their existing standalone Home Manager path.
- Centralize the shared shell configuration so future zsh changes apply consistently to desktop and homelab profiles.

## Non-goals

- Do not install the desktop Home Manager module stack on homelab hosts.
- Do not change Kubernetes resources directly; this is a NixOS/Home Manager repo change only.
- Do not redesign the shell prompt, aliases, or plugin choices beyond small guards needed for server safety.
- Do not migrate desktop hosts to Home Manager-as-a-NixOS-module in this change.

## Current State

- `modules/nixos/core/user.nix` already enables zsh system-wide and sets `users.defaultUserShell = pkgs.zsh`, so NixOS hosts launch zsh by default.
- The richer user shell configuration lives in `modules/home/desktop/shell/zsh/default.nix`, reached through `modules/home/desktop/default.nix`.
- Standalone Home Manager outputs exist for `roche@kiptum` and `roche@kipchoge` only.
- Homelab hosts (`dauwalter`, `kipsang`, `fordyce`, `selassie`, `walmsley`) are NixOS configurations only, so they miss the Home Manager-managed zsh files.

## Design

### Shared Home Manager shell module

Move the zsh-specific Home Manager module out of the desktop-only tree into a shared shell location, for example `modules/home/shell/zsh/`. The module should keep the existing zsh behavior but be safe on non-desktop hosts:

- Preserve `programs.zsh`, aliases, zplug plugins, Atuin, Starship, and the `nvim` wrapper.
- Keep desktop imports working by having `modules/home/desktop/shell/default.nix` import the shared zsh module instead of a desktop-local zsh module.
- Add command-existence guards around shell startup integrations that can fail noisily when packages are absent or delayed, such as `kubectl completion zsh` and `zoxide init zsh`.
- Keep Starship theme integration with Stylix when available, but provide a deterministic fallback palette so the shared zsh module can evaluate in a minimal homelab Home Manager profile.

### Homelab Home Manager profile

Create a lightweight Home Manager profile for `roche` on homelab hosts, for example `home/roche/homelab.nix`:

- Set `home.username`, `home.homeDirectory`, and `home.stateVersion` for `roche`.
- Import only the shared shell module and minimal user shell settings.
- Add only CLI packages needed by the shell experience and aliases, such as `bat`, `eza`, `fzf`, `jq`, `kubectl`, `lazygit`, `zoxide`, and other required non-GUI tools.
- Avoid importing `../../modules/home` or `../../modules/home/desktop`, because those bring desktop theming, GUI packages, and desktop services.

### NixOS wiring for homelab hosts only

Add a NixOS module that enables the Home Manager NixOS module for `roche` with the homelab profile:

- Import `inputs.hm.nixosModules.home-manager`.
- Configure `home-manager.useGlobalPkgs = true` and `home-manager.useUserPackages = true`.
- Pass the same flake arguments used elsewhere if needed.
- Optionally set a backup extension for unmanaged dotfile collisions during first activation.

Wire that module only for the homelab/server host set in `hosts/default.nix`:

- `dauwalter`
- `kipsang`
- `fordyce`
- `selassie`
- `walmsley`

Do not include `kiptum` or `kipchoge`, because those continue to use standalone Home Manager configurations.

## Alternatives Considered

### Import full Home Manager core on homelab

This would reuse more existing configuration with less splitting, but it risks installing GUI packages and Stylix/desktop assumptions on servers. It also makes the server profile harder to reason about.

### Copy zsh config into a NixOS module

This is quick, but duplicates shell configuration between desktop and homelab. Future shell edits would need to be kept in sync manually.

### Enable Home Manager as a NixOS module for all hosts

This would make all hosts consistent, but it could conflict with the existing standalone Home Manager management on desktop hosts and expands the scope beyond the requested homelab fix.

## Verification

This is a Nix configuration change, so new automated tests are not planned. Verification should use Nix evaluation/build commands instead:

- Run `nix flake check` after the change.
- Build at least one affected homelab host with `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`.
- Prefer building all affected homelab hosts if evaluation/build time is acceptable.
- Confirm desktop Home Manager outputs still evaluate for `roche@kiptum` and `roche@kipchoge`.

## Rollout

After merging, deploy with the existing NixOS deploy flow for homelab hosts. On first activation, Home Manager may need to back up pre-existing unmanaged shell dotfiles if they exist; the NixOS Home Manager module should be configured to handle that safely.
