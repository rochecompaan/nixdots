#!/usr/bin/env python3
"""Migrate recent pass additions to 1Password without writing plaintext files.

This intentionally remains one executable for drop-in use and auditability. Its
pure parsing/matching core and subprocess adapters are separated into sections.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from collections import defaultdict
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from enum import Enum
from pathlib import Path, PurePosixPath
from urllib.parse import SplitResult, urlsplit, urlunsplit


# Pass entry model, parsing, and classification


class MigrationError(Exception):
    """Base class for sanitized migration failures."""


class EntryParseError(MigrationError):
    """The decrypted pass entry could not be parsed safely."""


class Category(str, Enum):
    LOGIN = "Login"
    API_CREDENTIAL = "API Credential"
    PASSWORD = "Password"


@dataclass(frozen=True)
class CustomField:
    label: str
    value: str
    concealed: bool


@dataclass(frozen=True)
class SourceEntry:
    path: str
    title: str
    secret: str
    usernames: tuple[str, ...]
    urls: tuple[str, ...]
    totp: tuple[str, ...]
    custom_fields: tuple[CustomField, ...]
    notes: str


USERNAME_LABELS = {"username", "user", "login", "email"}
URL_LABELS = {"url", "uri", "website", "http", "https"}
TOTP_LABELS = {"otp", "totp", "one time password"}
SECRET_LABEL_WORDS = {"password", "secret", "token", "key", "credential", "code"}
API_MARKERS = (
    "api",
    "api key",
    "apikey",
    "token",
    "access key",
    "secret key",
    "client secret",
    "credential",
)


def _normalize_unicode(value: str) -> str:
    return unicodedata.normalize("NFKC", value)


def normalize_title(value: str) -> str:
    return " ".join(_normalize_unicode(value).strip().casefold().split())


def normalize_label(value: str) -> str:
    separated = re.sub(r"[_-]+", " ", _normalize_unicode(value))
    return " ".join(separated.strip().casefold().split())


def normalize_username(value: str) -> str:
    return _normalize_unicode(value).strip().casefold()


def _is_secret_label(label: str) -> bool:
    return bool(set(normalize_label(label).split()) & SECRET_LABEL_WORDS)


def parse_pass_output(entry_path: str, output: str) -> SourceEntry:
    lines = output.splitlines()
    if not lines or not lines[0]:
        raise EntryParseError("entry has no primary secret")

    usernames: list[str] = []
    urls: list[str] = []
    totp: list[str] = []
    custom_fields: list[CustomField] = []
    notes: list[str] = []

    for line in lines[1:]:
        stripped = line.strip()
        if stripped.startswith("otpauth://"):
            totp.append(stripped)
            continue
        if ":" not in line:
            notes.append(line)
            continue

        raw_label, raw_value = line.split(":", 1)
        label = raw_label.strip()
        value = raw_value.strip()
        normalized = normalize_label(label)
        if not value:
            custom_fields.append(CustomField(label, value, _is_secret_label(label)))
        elif normalized in USERNAME_LABELS:
            usernames.append(value)
        elif normalized in URL_LABELS:
            if normalized in {"http", "https"} and value.startswith("//"):
                value = f"{normalized}:{value}"
            urls.append(value)
        elif normalized in TOTP_LABELS or value.startswith("otpauth://"):
            totp.append(value)
        else:
            custom_fields.append(CustomField(label, value, _is_secret_label(label)))

    return SourceEntry(
        path=entry_path,
        title=PurePosixPath(entry_path).name,
        secret=lines[0],
        usernames=tuple(usernames),
        urls=tuple(urls),
        totp=tuple(totp),
        custom_fields=tuple(custom_fields),
        notes="\n".join(notes).strip(),
    )


def classify_entry(entry: SourceEntry) -> Category:
    title = normalize_label(entry.title)
    labels = {normalize_label(field.label) for field in entry.custom_fields}
    title_has_marker = any(
        re.search(rf"(?:^| ){re.escape(marker)}(?:$| )", title) for marker in API_MARKERS
    )
    if title_has_marker or labels.intersection(API_MARKERS):
        return Category.API_CREDENTIAL
    if entry.usernames or entry.urls:
        return Category.LOGIN
    return Category.PASSWORD


# Process and password-store adapters


class CommandError(MigrationError):
    """A child command failed without exposing its output."""


Runner = Callable[..., str]


def run_command(
    args: Sequence[str],
    *,
    input_text: str | None = None,
    env_updates: dict[str, str] | None = None,
) -> str:
    environment = os.environ.copy()
    if env_updates:
        environment.update(env_updates)
    completed = subprocess.run(
        list(args),
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
    )
    if completed.returncode != 0:
        raise CommandError(
            f"{args[0]} command failed with exit status {completed.returncode}"
        )
    return completed.stdout


def discover_entries(
    store: Path,
    since: str,
    *,
    runner: Runner = run_command,
) -> list[str]:
    raw = runner(
        [
            "git",
            "-C",
            str(store),
            "log",
            f"--since={since}",
            "--diff-filter=A",
            "--name-only",
            "--format=",
            "-z",
            "--",
            "*.gpg",
        ]
    )
    entries: set[str] = set()
    for relative in raw.split("\0"):
        if not relative or not relative.endswith(".gpg"):
            continue
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts:
            continue
        current_file = store.joinpath(*path.parts)
        if current_file.is_file():
            entries.add(relative.removesuffix(".gpg"))
    return sorted(entries)


def decrypt_entry(
    store: Path,
    entry_path: str,
    *,
    runner: Runner = run_command,
) -> str:
    return runner(
        ["pass", "show", "--", entry_path],
        env_updates={"PASSWORD_STORE_DIR": str(store)},
    )


# 1Password payload mapping, matching, and adapters


def _decode_json(raw: str, context: str) -> object:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise CommandError(f"op returned invalid JSON for {context}") from error


def _json_object(raw: str, context: str) -> dict[str, object]:
    decoded = _decode_json(raw, context)
    if not isinstance(decoded, dict):
        raise CommandError(f"op returned invalid {context} response")
    return decoded


def _object_list(value: object, context: str) -> list[dict[str, object]]:
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise CommandError(f"op returned invalid {context} response")
    return value


def _json_object_list(raw: str, context: str) -> list[dict[str, object]]:
    return _object_list(_decode_json(raw, context), context)


@dataclass(frozen=True)
class ItemSummary:
    id: str
    title: str
    category: str


@dataclass(frozen=True)
class ExistingItem:
    id: str
    title: str
    usernames: tuple[str, ...]
    urls: tuple[str, ...]
    pass_paths: tuple[str, ...]


class MatchKind(str, Enum):
    NONE = "none"
    MATCH = "match"
    AMBIGUOUS = "ambiguous"


@dataclass(frozen=True)
class MatchResult:
    kind: MatchKind
    item_ids: tuple[str, ...] = ()


TEMPLATE_NAMES = {
    Category.LOGIN: "Login",
    Category.API_CREDENTIAL: "API Credential",
    Category.PASSWORD: "Password",
}


def canonicalize_url(value: str) -> str:
    stripped = value.strip()
    parsed = urlsplit(stripped)
    if not parsed.scheme or not parsed.hostname:
        return normalize_title(stripped)
    scheme = parsed.scheme.casefold()
    hostname = parsed.hostname.casefold()
    port = parsed.port
    if port is not None and not (
        (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
    ):
        hostname = f"{hostname}:{port}"
    normalized = SplitResult(
        scheme,
        hostname,
        parsed.path or "/",
        parsed.query,
        "",
    )
    return urlunsplit(normalized)


def _set_builtin(payload: dict[str, object], field_id: str, value: str) -> None:
    for field in payload.get("fields", []):
        if field.get("id") == field_id:
            field["value"] = value
            return
    raise EntryParseError(f"1Password template has no {field_id} field")


def _append_custom(
    payload: dict[str, object], label: str, field_type: str, value: str
) -> None:
    fields = payload.setdefault("fields", [])
    fields.append(
        {
            "id": f"passMigration{len(fields):03d}",
            "type": field_type,
            "label": label,
            "value": value,
        }
    )


def build_item_payload(
    entry: SourceEntry,
    category: Category,
    template: dict[str, object],
) -> dict[str, object]:
    payload = copy.deepcopy(template)
    payload["title"] = entry.title
    tags = list(payload.get("tags", []))
    if "migrated-from-pass" not in tags:
        tags.append("migrated-from-pass")
    payload["tags"] = tags

    secret_id = "credential" if category is Category.API_CREDENTIAL else "password"
    _set_builtin(payload, secret_id, entry.secret)
    _set_builtin(payload, "notesPlain", entry.notes)
    if entry.usernames and category in {Category.LOGIN, Category.API_CREDENTIAL}:
        _set_builtin(payload, "username", entry.usernames[0])

    if category is Category.LOGIN:
        payload["urls"] = [
            {"label": "website", "primary": index == 0, "href": url}
            for index, url in enumerate(entry.urls)
        ]
    elif category is Category.API_CREDENTIAL and entry.urls:
        hostname = urlsplit(entry.urls[0]).hostname or ""
        _set_builtin(payload, "hostname", hostname)
        for index, url in enumerate(entry.urls, 1):
            _append_custom(payload, f"url {index}", "STRING", url)
    else:
        for index, url in enumerate(entry.urls, 1):
            _append_custom(payload, f"url {index}", "STRING", url)

    first_custom_username = 1 if category is Category.PASSWORD else 2
    for index, username in enumerate(
        entry.usernames[first_custom_username - 1 :], first_custom_username
    ):
        _append_custom(payload, f"email {index}", "STRING", username)
    for index, value in enumerate(entry.totp, 1):
        label = "one-time password" if index == 1 else f"one-time password {index}"
        _append_custom(payload, label, "OTP", value)
    for field in entry.custom_fields:
        _append_custom(
            payload,
            field.label,
            "CONCEALED" if field.concealed else "STRING",
            field.value,
        )
    _append_custom(payload, "pass path", "STRING", entry.path)
    return payload


def existing_item_from_json(raw: dict[str, object]) -> ExistingItem:
    item_id = raw.get("id")
    if not isinstance(item_id, str) or not item_id:
        raise CommandError("op returned invalid item detail response")
    title = raw.get("title", "")
    if not isinstance(title, str):
        raise CommandError("op returned invalid item detail response")

    usernames: list[str] = []
    urls = [
        str(item.get("href", ""))
        for item in _object_list(raw.get("urls", []), "item URL")
        if item.get("href")
    ]
    pass_paths: list[str] = []
    for field in _object_list(raw.get("fields", []), "item field"):
        if str(field.get("type", "")).upper() == "CONCEALED":
            continue
        field_id = str(field.get("id", ""))
        label = normalize_label(str(field.get("label", "")))
        value = str(field.get("value", ""))
        purpose = str(field.get("purpose", ""))
        is_username = (
            field_id == "username"
            or purpose == "USERNAME"
            or re.fullmatch(r"(?:username|user|login|email)(?: \d+)?", label)
        )
        if value and is_username:
            usernames.append(value)
        elif value and label == "pass path":
            pass_paths.append(value)
        elif value and (
            label in URL_LABELS
            or re.fullmatch(r"(?:url|uri|website)(?: \d+)?", label)
        ):
            urls.append(value)
    return ExistingItem(
        id=item_id,
        title=title,
        usernames=tuple(usernames),
        urls=tuple(urls),
        pass_paths=tuple(pass_paths),
    )


def match_existing(entry: SourceEntry, items: list[ExistingItem]) -> MatchResult:
    path_matches = sorted({item.id for item in items if entry.path in item.pass_paths})
    if path_matches:
        kind = MatchKind.MATCH if len(path_matches) == 1 else MatchKind.AMBIGUOUS
        return MatchResult(kind, tuple(path_matches))

    same_title = [
        item for item in items if normalize_title(item.title) == normalize_title(entry.title)
    ]
    source_usernames = {normalize_username(value) for value in entry.usernames}
    source_urls = {canonicalize_url(value) for value in entry.urls}
    if not source_usernames and not source_urls:
        identifier_matches = same_title
    else:
        identifier_matches = [
            item
            for item in same_title
            if source_usernames.intersection(
                normalize_username(value) for value in item.usernames
            )
            or source_urls.intersection(canonicalize_url(value) for value in item.urls)
        ]
    ids = tuple(sorted({item.id for item in identifier_matches}))
    if not ids:
        return MatchResult(MatchKind.NONE)
    if len(ids) == 1:
        return MatchResult(MatchKind.MATCH, ids)
    return MatchResult(MatchKind.AMBIGUOUS, ids)


def load_templates(*, runner: Runner = run_command) -> dict[Category, dict[str, object]]:
    templates: dict[Category, dict[str, object]] = {}
    for category, template_name in TEMPLATE_NAMES.items():
        template = _json_object(
            runner(
                [
                    "op",
                    "item",
                    "template",
                    "get",
                    template_name,
                    "--format",
                    "json",
                ]
            ),
            f"{template_name} template",
        )
        _object_list(template.get("fields"), f"{template_name} template fields")
        templates[category] = template
    return templates


def list_item_summaries(
    vault: str, *, runner: Runner = run_command
) -> list[ItemSummary]:
    items = _json_object_list(
        runner(["op", "item", "list", "--vault", vault, "--format", "json"]),
        "item list",
    )
    summaries: list[ItemSummary] = []
    for item in items:
        item_id = item.get("id")
        title = item.get("title")
        category = item.get("category", "")
        if not isinstance(item_id, str) or not isinstance(title, str):
            raise CommandError("op returned invalid item list response")
        if not isinstance(category, str):
            raise CommandError("op returned invalid item list response")
        summaries.append(ItemSummary(item_id, title, category))
    return summaries


def get_existing_item(
    item_id: str, vault: str, *, runner: Runner = run_command
) -> ExistingItem:
    raw = _json_object(
        runner(
            ["op", "item", "get", item_id, "--vault", vault, "--format", "json"]
        ),
        "item detail",
    )
    return existing_item_from_json(raw)


def create_item(
    payload: dict[str, object],
    vault: str,
    *,
    runner: Runner = run_command,
) -> dict[str, object]:
    raw = runner(
        ["op", "item", "create", "--vault", vault, "--format", "json", "-"],
        input_text=json.dumps(payload),
    )
    created = _json_object(raw, "created item")
    if not isinstance(created.get("id"), str) or not created["id"]:
        raise CommandError("op item create returned no item ID")
    return created


# Migration orchestration and CLI


@dataclass(frozen=True)
class Options:
    store: Path
    vault: str
    since: str
    apply: bool


@dataclass
class Counts:
    discovered: int = 0
    skipped: int = 0
    planned: int = 0
    created: int = 0
    ambiguous: int = 0
    failed: int = 0


@dataclass
class MigrationContext:
    templates: dict[Category, dict[str, object]]
    summaries: dict[str, list[ItemSummary]]
    details: dict[str, ExistingItem]


def parse_args(argv: Sequence[str] | None = None) -> Options:
    parser = argparse.ArgumentParser(
        description=(
            "Copy recent password-store additions to 1Password. "
            "Dry run decrypts candidates but creates nothing."
        )
    )
    parser.add_argument(
        "--store",
        type=Path,
        default=Path(
            os.environ.get("PASSWORD_STORE_DIR", "~/.password-store")
        ).expanduser(),
    )
    parser.add_argument("--vault", default="Private")
    parser.add_argument("--since", default="6 months ago")
    parser.add_argument("--apply", action="store_true")
    parsed = parser.parse_args(argv)
    return Options(
        parsed.store.expanduser().resolve(), parsed.vault, parsed.since, parsed.apply
    )


def _index_summaries(items: list[ItemSummary]) -> dict[str, list[ItemSummary]]:
    index: dict[str, list[ItemSummary]] = defaultdict(list)
    for item in items:
        index[normalize_title(item.title)].append(item)
    return dict(index)


def preflight(
    options: Options,
    *,
    runner: Runner = run_command,
    which: Callable[[str], str | None] = shutil.which,
) -> MigrationContext:
    missing = [name for name in ("git", "pass", "op") if which(name) is None]
    if missing:
        raise MigrationError(f"missing required commands: {', '.join(missing)}")
    if not options.store.is_dir():
        raise MigrationError("password store directory does not exist")
    inside = runner(
        ["git", "-C", str(options.store), "rev-parse", "--is-inside-work-tree"]
    ).strip()
    if inside != "true":
        raise MigrationError("password store is not a Git working tree")
    runner(["op", "vault", "get", options.vault, "--format", "json"])
    templates = load_templates(runner=runner)
    summaries = _index_summaries(list_item_summaries(options.vault, runner=runner))
    return MigrationContext(templates, summaries, {})


def _source_as_existing(entry: SourceEntry, item_id: str) -> ExistingItem:
    return ExistingItem(
        item_id,
        entry.title,
        entry.usernames,
        entry.urls,
        (entry.path,),
    )


def _add_in_memory_item(
    context: MigrationContext,
    entry: SourceEntry,
    category: Category,
    item_id: str,
) -> None:
    summary = ItemSummary(item_id, entry.title, category.value)
    context.summaries.setdefault(normalize_title(entry.title), []).append(summary)
    context.details[item_id] = _source_as_existing(entry, item_id)


def _sanitized_reason(error: Exception) -> str:
    if isinstance(error, MigrationError):
        return str(error)
    if isinstance(error, json.JSONDecodeError):
        return "command returned invalid JSON"
    if isinstance(error, KeyError):
        return "command response omitted a required field"
    if isinstance(error, ValueError):
        return "entry contains an invalid metadata value"
    if isinstance(error, OSError):
        return "local I/O operation failed"
    return "unexpected migration failure"


def _candidate_items(
    context: MigrationContext,
    entry: SourceEntry,
    vault: str,
    runner: Runner,
) -> list[ExistingItem]:
    candidates: list[ExistingItem] = []
    for summary in context.summaries.get(normalize_title(entry.title), []):
        if summary.id not in context.details:
            context.details[summary.id] = get_existing_item(
                summary.id, vault, runner=runner
            )
        candidates.append(context.details[summary.id])
    return candidates


def _handle_existing_match(
    match: MatchResult,
    entry: SourceEntry,
    category: Category,
    counts: Counts,
    output: Callable[[str], None],
) -> bool:
    if match.kind is MatchKind.MATCH:
        counts.skipped += 1
        output(f"SKIP {entry.path} [{category.value}] item={match.item_ids[0]}")
        return True
    if match.kind is MatchKind.AMBIGUOUS:
        counts.ambiguous += 1
        output(
            f"AMBIGUOUS {entry.path} [{category.value}] "
            f"items={','.join(match.item_ids)}"
        )
        return True
    return False


def _process_entry(
    options: Options,
    context: MigrationContext,
    counts: Counts,
    entry_path: str,
    runner: Runner,
    output: Callable[[str], None],
) -> None:
    decrypted = decrypt_entry(options.store, entry_path, runner=runner)
    entry = parse_pass_output(entry_path, decrypted)
    category = classify_entry(entry)
    match = match_existing(
        entry, _candidate_items(context, entry, options.vault, runner)
    )
    if _handle_existing_match(match, entry, category, counts, output):
        return
    if not options.apply:
        counts.planned += 1
        _add_in_memory_item(context, entry, category, f"planned:{entry.path}")
        output(f"CREATE {entry.path} [{category.value}]")
        return

    payload = build_item_payload(entry, category, context.templates[category])
    created = create_item(payload, options.vault, runner=runner)
    item_id = str(created["id"])
    _add_in_memory_item(context, entry, category, item_id)
    counts.created += 1
    output(f"CREATED {entry.path} [{category.value}] item={item_id}")


def execute(
    options: Options,
    *,
    runner: Runner = run_command,
    which: Callable[[str], str | None] = shutil.which,
    output: Callable[[str], None] = print,
) -> int:
    try:
        context = preflight(options, runner=runner, which=which)
    except (MigrationError, OSError, ValueError, KeyError) as error:
        output(f"ERROR preflight: {_sanitized_reason(error)}")
        return 2

    output(
        "Mode: APPLY"
        if options.apply
        else "Mode: DRY RUN (candidates will be decrypted; nothing will be created)"
    )
    counts = Counts()
    try:
        entries = discover_entries(options.store, options.since, runner=runner)
    except MigrationError as error:
        output(f"ERROR discovery: {error}")
        return 2
    counts.discovered = len(entries)

    for entry_path in entries:
        try:
            _process_entry(options, context, counts, entry_path, runner, output)
        except (MigrationError, OSError, ValueError, KeyError) as error:
            counts.failed += 1
            output(f"ERROR {entry_path}: {_sanitized_reason(error)}")

    output(
        "Summary: "
        f"discovered={counts.discovered} skipped={counts.skipped} "
        f"planned={counts.planned} created={counts.created} "
        f"ambiguous={counts.ambiguous} failed={counts.failed}"
    )
    return 1 if counts.ambiguous or counts.failed else 0


def main(argv: Sequence[str] | None = None) -> int:
    return execute(parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
