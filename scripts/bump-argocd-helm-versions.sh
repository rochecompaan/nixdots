#!/usr/bin/env bash
set -euo pipefail

# Bump Argo CD Helm app chart versions in ./argocd/base to latest available via helm repo index.
#
# Requirements: helm, yq (v4), coreutils (sha1sum)
#
# Usage:
#   scripts/bump-argocd-helm-versions.sh [--dry-run] [--allow-prerelease]
#
# Behavior:
# - Discovers apps by presence of .spec.source.helm in argocd/base/*/app.yaml
# - Adds per-repo temporary helm repo aliases derived from the repoURL
# - Queries latest stable version via `helm search repo` and updates targetRevision

DRY_RUN=false
ALLOW_PRERELEASE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --allow-prerelease|--devel)
      ALLOW_PRERELEASE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--allow-prerelease]" >&2
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

command -v helm >/dev/null 2>&1 || { echo "Error: helm not found in PATH" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "Error: yq not found in PATH" >&2; exit 1; }

# Map of repoURL -> alias to avoid re-adding
declare -A REPO_ALIAS

slugify() {
  # Slug a string for logging/display
  echo -n "$1" | sed -E 's#^https?://##; s#[^a-zA-Z0-9]+#-#g; s#(^-|-$)##g'
}

repo_alias_for() {
  local url="$1"
  if [[ -n "${REPO_ALIAS[$url]:-}" ]]; then
    echo -n "${REPO_ALIAS[$url]}"
    return 0
  fi
  # Stable alias based on URL hash to avoid collisions
  local hash
  if command -v sha1sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$url" | sha1sum | cut -c1-8)
  else
    # macOS fallback
    hash=$(printf '%s' "$url" | shasum | cut -c1-8)
  fi
  local alias="repo-${hash}"
  REPO_ALIAS[$url]="$alias"
  echo -n "$alias"
}

ensure_repo() {
  local url="$1"
  local alias
  alias=$(repo_alias_for "$url")

  # If alias already exists with same URL, skip; otherwise (re)add/force-update
  # helm repo list -o json is easier to parse with yq
  if helm repo list -o json 2>/dev/null | yq -e ".[] | select(.name == \"$alias\" and .url == \"$url\")" >/dev/null 2>&1; then
    :
  else
    echo "Adding helm repo '$alias' -> $url"
    helm repo add "$alias" "$url" --force-update >/dev/null
  fi
  echo -n "$alias"
}

latest_chart_version() {
  local repo_url="$1"
  local chart="$2"
  local alias
  alias=$(ensure_repo "$repo_url")

  local devel_flag=()
  if [[ "$ALLOW_PRERELEASE" == true ]]; then
    devel_flag=(--devel)
  fi

  # Use helm search against local repo indices. Ensure indices are up to date.
  # We do a targeted update for speed; if unsupported, a global update is fine as fallback.
  if ! helm repo update "$alias" >/dev/null 2>&1; then
    helm repo update >/dev/null
  fi

  # Query versions in JSON and take the first entry (newest by helm ordering)
  local latest
  if ! latest=$(helm search repo "$alias/$chart" -l -o json "${devel_flag[@]}" 2>/dev/null | yq -r '.[0].version // empty'); then
    latest=""
  fi
  echo -n "$latest"
}

update_app_file() {
  local file="$1"
  local chart repo_url current target latest

  # Only process apps with .spec.source.helm present
  if ! yq -e '.spec.source.helm' "$file" >/dev/null 2>&1; then
    return 0
  fi

  chart=$(yq -r '.spec.source.chart // empty' "$file")
  repo_url=$(yq -r '.spec.source.repoURL // empty' "$file")
  target=$(yq -r '.spec.source.targetRevision // empty' "$file")

  if [[ -z "$chart" || -z "$repo_url" ]]; then
    echo "[SKIP] $(slugify "$file"): missing chart or repoURL" >&2
    return 0
  fi

  if [[ "$repo_url" == oci://* ]]; then
    echo "[WARN] $(slugify "$file"): oci repo not supported for auto-latest with helm search; skipping" >&2
    return 0
  fi

  latest=$(latest_chart_version "$repo_url" "$chart")
  if [[ -z "$latest" ]]; then
    echo "[WARN] $(slugify "$file"): unable to determine latest version for $repo_url/$chart" >&2
    return 0
  fi

  if [[ "$target" == "$latest" ]]; then
    echo "[OK]   $(slugify "$file"): up-to-date ($chart $target)"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "[PLAN] $(slugify "$file"): $chart $target -> $latest"
  else
    echo "[EDIT] $(slugify "$file"): $chart $target -> $latest"
    # Use Python yq (jq wrapper) in-place edit which requires -y with -i
    yq -y -i ".spec.source.targetRevision = \"$latest\"" "$file"
  fi
}

main() {
  local base_dir="argocd/base"
  local count=0

  if [[ ! -d "$base_dir" ]]; then
    echo "Error: $base_dir not found" >&2
    exit 1
  fi

  # Iterate app.yaml files under argocd/base
  while IFS= read -r -d '' file; do
    update_app_file "$file"
    ((count++)) || true
  done < <(find "$base_dir" -maxdepth 2 -type f -name 'app.yaml' -print0 | sort -z)

  if [[ "$count" -eq 0 ]]; then
    echo "No app.yaml files found under $base_dir" >&2
  fi
}

main "$@"
