import os
import shlex
from pathlib import Path


def default_store_dir() -> Path:
    if value := os.environ.get("PASSWORD_STORE_DIR"):
        return Path(value).expanduser()
    return Path.home() / ".password-store"


def hook_script(index_command: str) -> str:
    quoted_command = shlex.quote(index_command)
    return f'''#!/usr/bin/env bash
set -u

index_cmd={quoted_command}

entry_from_path() {{
  local path="$1"
  case "$path" in
    *.gpg) printf '%s\\n' "${{path%.gpg}}" ;;
    *) return 1 ;;
  esac
}}

update_entry() {{
  local entry
  entry="$(entry_from_path "$1")" || return 0
  "$index_cmd" update --entry "$entry" --store-dir "$PWD" >/dev/null || \
    printf 'passff-shared-index: failed to update %s\\n' "$entry" >&2
}}

remove_entry() {{
  local entry
  entry="$(entry_from_path "$1")" || return 0
  "$index_cmd" remove --entry "$entry" --store-dir "$PWD" >/dev/null || \
    printf 'passff-shared-index: failed to remove %s\\n' "$entry" >&2
}}

process_diff() {{
  local status old_path new_path path
  while IFS= read -r -d '' status; do
    case "$status" in
      D*)
        IFS= read -r -d '' old_path || break
        remove_entry "$old_path"
        ;;
      R*)
        IFS= read -r -d '' old_path || break
        IFS= read -r -d '' new_path || break
        remove_entry "$old_path"
        update_entry "$new_path"
        ;;
      C*)
        IFS= read -r -d '' old_path || break
        IFS= read -r -d '' new_path || break
        update_entry "$new_path"
        ;;
      *)
        IFS= read -r -d '' path || break
        update_entry "$path"
        ;;
    esac
  done
}}

case "$(basename "$0")" in
  post-commit)
    if git rev-parse --verify HEAD^ >/dev/null 2>&1; then
      git diff --name-status -z HEAD^ HEAD | process_diff
    else
      git diff-tree --no-commit-id --name-status -z -r --root HEAD | process_diff
    fi
    ;;
  post-merge)
    git rev-parse --verify ORIG_HEAD >/dev/null 2>&1 || exit 0
    git diff --name-status -z ORIG_HEAD HEAD | process_diff
    ;;
esac
'''


def install_git_hooks(
    *,
    store_dir: os.PathLike[str] | str | None = None,
    index_command: str = "passff-shared-index",
) -> list[Path]:
    store = Path(store_dir) if store_dir is not None else default_store_dir()
    hooks_dir = store / ".git" / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    script = hook_script(index_command)
    installed: list[Path] = []
    for name in ["post-commit", "post-merge"]:
        path = hooks_dir / name
        path.write_text(script, encoding="utf-8")
        os.chmod(path, 0o755)
        installed.append(path)
    return installed
