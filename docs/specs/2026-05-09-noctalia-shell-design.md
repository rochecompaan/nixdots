# Noctalia Shell Home Manager Design

## Context

The Niri desktop currently starts Waybar from `modules/home/desktop/wayland/niri/config/autostart.nix`, and desktop services import both Waybar and SwayNC from `modules/home/desktop/services/default.nix`. The flake already includes `inputs.noctalia`, and `home/default.nix` passes `inputs` into Home Manager modules through `extraSpecialArgs`.

A Noctalia settings file already exists at `modules/home/desktop/services/noctalia/noctalia.json`. It contains a top-level `settings` object suitable for Noctalia's Home Manager module.

## Goals

- Add Noctalia Shell to the Home Manager desktop configuration.
- Use Noctalia's provided Home Manager module: `inputs.noctalia.homeModules.default`.
- Load Noctalia settings from `modules/home/desktop/services/noctalia/noctalia.json` with:

  ```nix
  settings =
    (builtins.fromJSON
      (builtins.readFile ./noctalia.json)).settings;
  ```

- Replace Waybar for Niri during testing.
- Disable SwayNC if its notification/control-center features are absorbed by Noctalia Shell.
- Keep Waybar and SwayNC source files in place for now so rollback remains easy.

## Non-goals

- Do not add a long-term `desktopShell` selector option.
- Do not remove Waybar files, styles, modules, or the Waybar flake input yet.
- Do not remove SwayNC files yet.
- Do not redesign the Noctalia JSON settings in this change.

## Architecture

Add a dedicated service module at:

```text
modules/home/desktop/services/noctalia/default.nix
```

The module will:

1. Import `inputs.noctalia.homeModules.default`.
2. Enable `programs.noctalia-shell` only for desktop/Niri usage if needed.
3. Load settings from the adjacent `noctalia.json` file.

Wire the module into:

```text
modules/home/desktop/services/default.nix
```

Niri autostart will no longer launch Waybar. If Noctalia's Home Manager module provides its own startup integration, rely on that. If evaluation or module behavior shows that startup is not handled, add a Niri `spawn-at-startup` command for the Noctalia executable in `modules/home/desktop/wayland/niri/config/autostart.nix`.

## Service replacement behavior

During the testing phase:

- Disable `programs.waybar.enable` so Waybar is not configured or launched.
- Disable `services.swaync.enable` because Noctalia Shell is expected to cover notification/control-center behavior.
- Keep both modules imported and keep their files in the tree for easy rollback.

After testing succeeds, a later cleanup can remove the unused Waybar/SwayNC modules and any unused flake inputs.

## Verification

Run Home Manager evaluation for the affected profiles:

```sh
nix build .#homeConfigurations."roche@kiptum".activationPackage
nix build .#homeConfigurations."roche@kipchoge".activationPackage
```

Because `modules/home/desktop/services/noctalia/default.nix` is a new file referenced by the flake, stage it before final normal flake verification, or use a path flake for pre-stage testing.
