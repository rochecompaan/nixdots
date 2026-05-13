# Roche Pi Dendritic Flake Design

## Context

The current Pi configuration lives in `modules/home/desktop/utils/pi` inside `nixdots`. It installs a global `~/.pi/agent` tree through Home Manager, builds several Pi package dependencies with Nix, and exposes custom extensions, skills, agents, agent teams, and a Stylix-derived theme.

The goal is to extract this into a separate personal-first repository that others can reuse and that projects can consume from their own flakes or devenv shells. The new repository should keep the current workflow intact while replacing repository-local assumptions with explicit options.

## Decision

Create a separate flake using the dendritic pattern described by Vimjoyer: keep `flake.nix` minimal, use `flake-parts`, and import the whole `modules/` tree with `import-tree`. Each branch under `modules/` contributes its own flake outputs close to the code it owns.

This will be a personal-first reusable Pi distribution, not a public-minimal package. Defaults should match the current Roche Pi setup where practical, while options allow disabling or overriding machine-specific pieces.

## Repository Shape

```text
roche-pi/
  flake.nix
  package.json
  README.md

  modules/
    parts.nix

    packages/
      pi-config.nix
      pi-remote.nix
      notion-cli.nix

    home/
      pi.nix
      jailed-pi.nix

    lib/
      settings.nix
      project-pi.nix
      theme.nix

    devshells/
      default.nix

  resources/
    extensions/
    skills/
    agents/
    agent-teams/
    themes/
```

`flake.nix` should only define inputs and call `inputs.import-tree ./modules` through `flake-parts`.

Initial supported systems should be limited to:

```nix
systems = [ "x86_64-linux" ];
```

Broader support for `aarch64-linux`, `x86_64-darwin`, and `aarch64-darwin` should be deferred until the package set is made more configurable and platform-sensitive dependencies are gated per system.

## Flake Outputs

The extracted repository should expose these first-class outputs:

```nix
packages.${system}.default
packages.${system}.pi-config
packages.${system}.pi-remote
packages.${system}.notion-cli

homeModules.default
homeModules.pi
homeModules.jailed-pi

lib.${system}.mkSettings
lib.${system}.mkStylixTheme
lib.${system}.projectPiShellHook
```

`packages.${system}.pi-config` is the central store-backed Pi resource package. `homeModules.default` installs it globally for a user. `lib.${system}.projectPiShellHook` enables project-local usage from another flake or devenv.

## Pi Resource Package

`pi-config` should produce a Nix store path that is both a Pi package and a resource tree for Home Manager symlinks:

```text
$out/
  package.json
  AGENTS.md
  settings.json
  extensions/
  skills/
  themes/
  agents/
  agent-teams/
  node_modules/
```

The `package.json` should declare Pi resources with the `pi` manifest:

```json
{
  "name": "@roche/pi-config",
  "keywords": ["pi-package"],
  "pi": {
    "extensions": ["./extensions"],
    "skills": ["./skills"],
    "themes": ["./themes"]
  }
}
```

Pi-native resources are `extensions`, `skills`, and `themes`. The package also carries `agents`, `agent-teams`, `AGENTS.md`, and generated settings because Roche workflows depend on subagent and team discovery paths that are not covered by Pi package manifests.

## Settings Generation

Move the current `settings.json` merge logic into `modules/lib/settings.nix`. The settings builder should accept options for:

- default provider, model, and thinking level
- theme name
- voice settings
- enabled Pi package dependencies
- extra packages
- extra extensions, skills, themes, agents, and agent teams
- active agent team defaults

For Nix-managed and jailed environments, generated settings must use Nix store paths for bundled package dependencies rather than raw runtime Git or npm URLs.

Default package dependencies should preserve the current setup:

- `@codexstar/pi-listen`
- `pi-messenger-bridge`
- `@noahsaso/pi-remote`
- `pi-subagents`
- `superpowers`

## Home Manager Module

`homeModules.default` and `homeModules.pi` should install the Pi config globally under `~/.pi/agent`.

Expected usage from `nixdots`:

```nix
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

The module should write or link:

```text
~/.pi/agent/AGENTS.md
~/.pi/agent/settings.json
~/.pi/agent/extensions
~/.pi/agent/skills
~/.pi/agent/themes/stylix.json
~/.pi/agent/agents
~/.pi/agent/agent-teams
~/.pi/agent/node_modules/diff
```

The module may also install `notion-cli` when enabled.

## Stylix Theme

The current `theme.nix` depends on `config.lib.stylix.colors`. In the extracted repo, Stylix integration should be optional:

- `programs.roche-pi.stylix.enable = true` uses Home Manager's `config.lib.stylix.colors`.
- If disabled, use a static bundled theme or Pi's built-in theme.
- `lib.${system}.mkStylixTheme` should generate the same theme structure from a Base16 color set.

This keeps the personal desktop behavior while allowing non-Stylix users to consume the package.

## Intervals Integration

The current config hard-codes symlinks to `${config.home.homeDirectory}/projects/pi/extensions/pi-intervals`. Replace that with explicit options:

```nix
programs.roche-pi.intervals = {
  enable = true;
  path = null;
  package = null;
};
```

When enabled, the module should add the extension and skill from either `path` or `package`. When disabled, no local intervals symlink is created. This preserves the current personal workflow without making a specific home-directory path mandatory.

## Project/Devenv Usage

Expose `lib.${system}.projectPiShellHook` for projects with their own flake or devenv. It should create or update a project-local `.pi` directory with settings that load the external store-backed Pi config package.

Example consuming project:

```nix
devShells.default = pkgs.mkShell {
  packages = [ inputs.llm-agents.packages.${system}.pi ];

  shellHook = ''
    ${inputs.roche-pi.lib.${system}.projectPiShellHook {
      agentTeam = "openai-only";
    }}
  '';
};
```

The hook should create:

```text
.pi/settings.json
.pi/agents -> ${piConfigPackage}/agents
.pi/agent-teams -> ${piConfigPackage}/agent-teams
```

`.pi/settings.json` should include the store path package in `packages`, plus project-specific overrides such as active agent team.

## Jailed Pi Module

Move the current jailed Pi integration out of `nixdots` only after the base package and Home Manager module exist. The extracted `homeModules.jailed-pi` should consume `packages.${system}.pi-config` instead of importing a local `files.nix`.

Jailed integration should remain optional because it depends on additional inputs and user-specific secret handling.

## Migration Plan

1. Create the new dendritic `roche-pi` repository structure.
2. Copy resources from `modules/home/desktop/utils/pi` into `resources/`.
3. Move package derivations into `modules/packages/`.
4. Move settings/theme generation into `modules/lib/`.
5. Implement `packages.${system}.pi-config`.
6. Implement `homeModules.default`.
7. Update `nixdots` to import `inputs.roche-pi.homeModules.default` and remove the local Pi module internals.
8. Add `projectPiShellHook` for flake/devenv consumers.
9. Move jailed Pi integration after the base path is verified.

## Testing

Minimum verification for the extracted repo:

- `nix flake check`
- `nix build .#packages.x86_64-linux.pi-config`
- `nix build .#packages.x86_64-linux.pi-remote`
- `nix build .#packages.x86_64-linux.notion-cli`
- evaluate an example Home Manager configuration using `homeModules.default`
- enter an example devshell and confirm `.pi/settings.json` points at the store package

Minimum verification for `nixdots` after migration:

- `nix build .#homeConfigurations."roche@kipchoge".activationPackage` or `nix build .#homeConfigurations."roche@kiptum".activationPackage`, depending on the migrated host
- inspect generated `~/.pi/agent/settings.json` in a build or dry run
- run Pi and confirm extensions, skills, subagents, and agent teams are discovered

## Platform Scope

The initial extraction should target `x86_64-linux` only. This matches the current `nixdots` flake and avoids prematurely abstracting platform-specific package pins.

Known platform-sensitive components include:

- `pi-listen`, which currently fetches `sherpa-onnx-linux-x64` artifacts.
- `pi-messenger-bridge`, which currently installs `matrix-sdk-crypto.linux-x64-gnu.node`.
- jailed Pi integration, which depends on Linux-oriented jail/bubblewrap behavior.

Future portability work should make these features optional or per-platform before adding more systems to the flake.

## Non-goals

- Do not make the defaults public-minimal; this is intentionally personal-first.
- Do not support non-`x86_64-linux` systems in the first extraction pass.
- Do not publish to npm initially; the Nix store path package is the primary distribution mechanism.
- Do not solve secrets or API key management inside the extracted package.
- Do not make direct Kubernetes or homelab changes as part of this work.
