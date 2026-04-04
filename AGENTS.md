# Repository Guidelines

## Project Structure & Module Organization
- Root: `flake.nix` (entry), `flake.lock`, `README.md`, `pre-commit-hooks.nix`, `scripts/`.
- NixOS: `modules/nixos/**` (core + opt), per-host files under `hosts/<host>/{default.nix,hardware-configuration.nix}`.
- Home Manager: `modules/home/**` (core, desktop, utils), per-user profiles under `home/<user>/*.nix`.
- Homelab Kubernetes: ArgoCD apps and overlays under `argocd/` with cluster-specific Kustomize in `argocd/homelab/**`.
- Shared assets: `home/shared/{walls,cols,icons}/`.
- Secrets: `secrets/**` (managed via sops-nix). Do not commit plaintext secrets.

## Build, Test, and Development Commands
- Check flake: `nix flake check` — evaluates configs and runs checks.
- Build NixOS for a host (no switch): `nixos-rebuild build --flake .#<host>`.
- Activate NixOS on target: `sudo nixos-rebuild switch --flake .#<host>`.
- Build/activate Home Manager: `home-manager switch --flake .#<user>@<host>`.
- Deploy helper: `scripts/deploy-nixos.sh <host>` — wraps common deploy steps.
- Lint Nix: `statix check .` (config in `statix.toml`).
- Format Nix: `nix fmt` (or `alejandra -q .` if installed).

## Homelab Kubernetes (ArgoCD)
- ArgoCD deploys the homelab cluster from this repo using Application CRs.
- `argocd/homelab/apps/kustomization.yaml` is the bootstrap bundle that installs
  ArgoCD and registers the rest of the Applications under `argocd/base/**`.
- App definitions reference either Helm charts or repo paths like
  `argocd/homelab/infra` and `argocd/homelab/local-path-provisioner`.
- Sync order is controlled with `argocd.argoproj.io/sync-wave`; apps are set to
  automated sync with prune/self-heal where appropriate.

## VERY IMPORTANT: GitOps-Only Cluster Changes
- Never apply or mutate homelab Kubernetes resources directly from a workstation.
- Do not run direct-write commands like `kubectl apply`, `kubectl patch`,
  `kubectl delete`, `helm upgrade`, or manual `argocd app sync` for homelab.
- All homelab changes must be made in this repo (ArgoCD app manifests, Helm
  values, Kustomize overlays) and delivered through Git so ArgoCD reconciles them.

## VERY IMPORTANT: Commit Signing And Escalation
- Never bypass git commit signing.
- Never bypass commit hooks as a workaround for sandbox restrictions.
- If signing/hooks fail because of sandbox limits, always request escalated
  sandbox permissions and retry the commit properly.

## Coding Style & Naming Conventions
- Nix: 2-space indent, trailing commas, one attr per line.
- Filenames: kebab-case for modules (e.g., `programs.nix`, `options.nix`, `default.nix`).
- Module shape: small, composable; expose options in `options.nix`, wire defaults in `default.nix`.
- Imports/attrs sorted alphabetically; avoid unused bindings; prefer explicit module inputs.

## Testing Guidelines
- Fast eval: `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`.
- HM eval: `nix build .#homeConfigurations."<user>@<host>".activationPackage`.
- Add host/user configs that evaluate on CI via `flake.nix` outputs.
- Tests live alongside modules when practical; prefer minimal, focused assertions.

## Commit & Pull Request Guidelines
- Commits: follow the Conventional Commits specification.
- Use standard commit types such as `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, and `revert`.
- Keep commits imperative, concise, and scoped when helpful. Examples:
  - `feat(nixos): add selassie host`
  - `feat(home): add wezterm config`
  - `fix(module): resolve statix warnings`
  - `chore(flake): update inputs`
- Do not use custom top-level types like `argocd`, `nixos`, or `home`; those belong in the scope, not the type.
- PRs: clear description, rationale, affected hosts/users, before/after screenshots for UI (waybar/swaync), and notes on secrets or migrations.

## Security & Configuration Tips
- Manage secrets with sops-nix; keep Age keys off-repo. Update items under `secrets/**` only via `sops`.
- Avoid leaking hostnames/paths in public diffs; prefer variables and options where possible.
