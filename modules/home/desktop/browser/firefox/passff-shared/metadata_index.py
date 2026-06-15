import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any

VERSION = "1.2.5"
INDEX_VERSION = 1
DEFAULT_FIELD_NAMES = ["url", "http", "https"]
PASS_COMMAND = os.environ.get("PASSFF_SHARED_PASS_COMMAND", "@PASS_COMMAND@")

PassRunner = Callable[..., subprocess.CompletedProcess[bytes]]


def default_index_path() -> Path:
    if value := os.environ.get("PASSFF_SHARED_INDEX_PATH"):
        return Path(value)
    if value := os.environ.get("XDG_CACHE_HOME"):
        cache_home = Path(value)
    else:
        cache_home = Path.home() / ".cache"
    return cache_home / "passff-shared" / "metadata-index.json"


def default_store_dir() -> Path:
    if value := os.environ.get("PASSWORD_STORE_DIR"):
        return Path(value).expanduser()
    return Path.home() / ".password-store"


def extract_metadata_fields(content: str, field_names: Iterable[str]) -> dict[str, list[str]]:
    wanted = {name.lower() for name in field_names}
    fields: dict[str, list[str]] = {}
    lines = content.splitlines()[1:]
    for line in lines:
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        normalized = name.strip().lower()
        if normalized not in wanted:
            continue
        value = value.strip()
        if not value:
            continue
        fields.setdefault(normalized, []).append(value)
    return fields


def build_grep_stdout(index: dict[str, Any], field_names: Iterable[str]) -> str:
    wanted = [name.lower() for name in field_names]
    chunks: list[str] = []
    for entry in index.get("entries", []):
        fields = entry.get("fields", {})
        lines: list[str] = []
        for name in wanted:
            for value in fields.get(name, []):
                lines.append(f"{name}: {value}")
        if not lines:
            continue
        chunks.append(f"{entry['path']}:\n" + "\n".join(lines) + "\n")
    return "".join(chunks)


def empty_index() -> dict[str, Any]:
    return {"version": INDEX_VERSION, "entries": []}


def load_index(index_path: os.PathLike[str] | str | None = None) -> dict[str, Any]:
    path = Path(index_path) if index_path is not None else default_index_path()
    if not path.exists():
        return empty_index()
    with path.open("r", encoding="utf-8") as handle:
        index = json.load(handle)
    if index.get("version") != INDEX_VERSION:
        return empty_index()
    return index


def write_index(index_path: os.PathLike[str] | str, index: dict[str, Any]) -> None:
    path = Path(index_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(index, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def iter_password_entries(store_dir: Path) -> Iterable[tuple[str, Path]]:
    for path in sorted(store_dir.rglob("*.gpg")):
        if ".git" in path.parts:
            continue
        entry = path.relative_to(store_dir).with_suffix("").as_posix()
        yield entry, path


def refresh_index(
    *,
    store_dir: os.PathLike[str] | str | None = None,
    index_path: os.PathLike[str] | str | None = None,
    field_names: Iterable[str] = DEFAULT_FIELD_NAMES,
    pass_command: str = PASS_COMMAND,
    runner: PassRunner = subprocess.run,
) -> dict[str, Any]:
    store = Path(store_dir) if store_dir is not None else default_store_dir()
    target = Path(index_path) if index_path is not None else default_index_path()
    entries: list[dict[str, Any]] = []

    for entry, path in iter_password_entries(store):
        proc = runner(
            [pass_command, "show", "--", entry],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            continue
        fields = extract_metadata_fields(proc.stdout.decode("UTF-8"), field_names)
        if not fields:
            continue
        entries.append(
            {
                "path": entry,
                "fields": fields,
                "mtime": int(path.stat().st_mtime),
            }
        )

    index = {"version": INDEX_VERSION, "entries": entries}
    write_index(target, index)
    return index


def run_metadata_request(message: list[Any], *, index_path: os.PathLike[str] | str | None = None) -> dict[str, Any]:
    if not (len(message) == 2 and message[0] == "grepMetaUrls" and isinstance(message[1], list)):
        return {"exitCode": 1, "stdout": "", "stderr": "unsupported metadata request", "version": VERSION}
    index = load_index(index_path)
    stdout = build_grep_stdout(index, [str(value) for value in message[1]])
    return {"exitCode": 0, "stdout": stdout, "stderr": "", "version": VERSION}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manage the shared PassFF metadata index")
    subcommands = parser.add_subparsers(dest="command", required=True)
    refresh = subcommands.add_parser("refresh", help="Refresh the host-only URL metadata index")
    refresh.add_argument("--store-dir", default=None)
    refresh.add_argument("--index-path", default=None)
    refresh.add_argument("--fields", default=",".join(DEFAULT_FIELD_NAMES))
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args(sys.argv[1:])
    if args.command == "refresh":
        fields = [field.strip() for field in args.fields.split(",") if field.strip()]
        index = refresh_index(store_dir=args.store_dir, index_path=args.index_path, field_names=fields)
        print(f"indexed {len(index['entries'])} entries at {args.index_path or default_index_path()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
