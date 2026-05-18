# Streamlinear dendritic package design

## Goal

Refactor the Streamlinear Home Manager service so the upstream CLI is available as a reusable flake package:

```nix
inputs.nixdots.packages.${pkgs.system}.streamlinear
```

The exported package must be raw and reusable: it must not depend on this user's SOPS secret layout or automatically read a token file. Home Manager integration may wrap the raw package to inject `LINEAR_API_TOKEN` for this host profile.

## Architecture

Use the same dendritic style as `roche-pi`: colocated flake-parts modules contribute package outputs, while Home Manager modules consume those outputs through an overridable `package` option.

Add a package implementation under `nix/packages/streamlinear.nix`. Add a flake-parts module under `modules/packages/streamlinear.nix` that exposes:

```nix
packages.streamlinear
checks.streamlinear-build
```

Add a flake-parts module that exposes the reusable Home Manager module as `flake.homeModules.streamlinear` and, if useful, `flake.homeModules.default` only when that does not conflict with existing home module exports. Import these flake-parts modules from `flake.nix` alongside the existing explicit imports. This is dendritic enough for the target package without converting the whole repository to `import-tree`.

## Raw package behavior

The raw package builds the upstream `obra/streamlinear` MCP subdirectory and installs executables:

- `streamlinear` for the stdio MCP server
- `streamlinear-cli` for direct CLI usage

It should not contain token-loading shell code. Consumers are responsible for setting `LINEAR_API_TOKEN` in their shell, devShell, or service environment.

## Home Manager behavior

Refactor `modules/home/desktop/services/streamlinear/default.nix` into a small Home Manager integration module. It should expose options under `programs.streamlinear`:

- `enable`: enable installation and user service integration
- `package`: raw Streamlinear package, defaulting to `self.packages.${pkgs.system}.streamlinear`
- `tokenFile`: nullable absolute path used by local wrappers to populate `LINEAR_API_TOKEN` when unset
- `mcpSocket.enable`: enable the socket-activated MCP service

The reusable Home Manager module should not require SOPS or `inputs.nix-secrets` by default. This repository's desktop profile should opt in by enabling the module, declaring the existing SOPS secret, and setting `programs.streamlinear.tokenFile` to that secret path. The wrappers and systemd units must remain Home Manager-only, not part of the reusable package.

## Data flow

External flakes use the raw package directly and provide their own environment:

```nix
pkgs.mkShell {
  packages = [ inputs.nixdots.packages.${pkgs.system}.streamlinear ];
}
```

This repository's Home Manager profile installs a wrapped package. The wrapper checks `LINEAR_API_TOKEN`; if unset and `tokenFile` is readable, it exports the token before executing the raw binary.

The socket-activated user service runs the wrapped `streamlinear` command so the local MCP server inherits the same token behavior as the interactive CLI.

## Error handling and constraints

- If `tokenFile = null`, wrappers should not try to read a token file.
- If `LINEAR_API_TOKEN` is already set, wrappers must not override it.
- If a configured token file is missing or unreadable, wrappers should exec the raw command and let Streamlinear report authentication failures.
- Package output must evaluate without Home Manager `config` or `inputs.nix-secrets`.
- New Nix files must be imported by the flake so `nix build .#streamlinear` and external `inputs.nixdots.packages.${system}.streamlinear` work.

## Verification

Run focused checks after implementation:

```sh
nix build .#streamlinear
nix build .#homeConfigurations."roche@kiptum".activationPackage
nix fmt
```

If new files are untracked during early checks, use a path flake or stage files before normal flake verification so Nix includes them in the source tree.
