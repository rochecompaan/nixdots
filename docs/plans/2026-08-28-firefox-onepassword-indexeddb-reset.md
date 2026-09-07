# Firefox 1Password IndexedDB Reset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe command that removes corrupt 1Password IndexedDB data from selected Firefox profiles.

**Architecture:** Keep discovery, parsing, path checks, preflight, confirmation, and removal in one auditable Python script. Use immutable data classes and small functions so unit tests can exercise every safety boundary without real Firefox data.

**Tech Stack:** Python 3 standard library, `argparse`, `configparser`, `json`, `pathlib`, `unittest`, Git

## Global Constraints

- Work only in `/home/roche/nixdots/.worktrees/reset-firefox-onepassword-indexeddb` on `feat/reset-firefox-onepassword-indexeddb`.
- Do not modify `modules/home/desktop/wayland/niri/config/autostart.nix` in any checkout.
- Follow `docs/specs/2026-08-28-firefox-onepassword-indexeddb-reset-design.md`.
- Create `scripts/reset-firefox-onepassword-indexeddb.py` as the only production file.
- Create `scripts/tests/test_reset_firefox_onepassword_indexeddb.py` as the only new test file.
- Use only the Python standard library.
- Support repeated `--profile NAME` arguments and mutually exclusive `--all` selection.
- Support relative and absolute profile paths from `profiles.ini`.
- Require `--all` or at least one `--profile NAME` argument.
- Support `--yes` to bypass the interactive prompt.
- Refuse the operation while a `firefox` or `firefox-bin` process exists under `/proc`.
- Resolve `{d634138d-c276-4fc8-924b-40a0ea21d284}` through `extensions.webextensions.uuids` in each selected `prefs.js`.
- Remove only `<profile>/storage/default/moz-extension+++<uuid>/idb`.
- Complete every preflight check before the first removal.
- Treat an absent `idb` directory as a successful no-op.
- Return exit code `0` for reset, no-op, or cancellation.
- Return a nonzero exit code for argument, preflight, or removal errors.
- Do not show IndexedDB child names or contents in output or errors.
- Do not start Firefox or call another process after the reset.
- Use temporary directories and synthetic profile data in tests.
- Keep the 30 baseline tests green.
- Use the repository `commit` skill before each commit.
- Do not add a unit test that only checks source text or file mode. Use direct verification for those properties.

---

## File Structure

- `scripts/reset-firefox-onepassword-indexeddb.py`: Own the CLI, Firefox profile discovery, UUID parsing, target checks, preflight, preview, confirmation, removal, and result output.
- `scripts/tests/test_reset_firefox_onepassword_indexeddb.py`: Own unit and integration-style tests against temporary Firefox trees and synthetic `/proc` trees.
- `docs/specs/2026-08-28-firefox-onepassword-indexeddb-reset-design.md`: Approved behavior source. Do not modify it during implementation.
- `docs/plans/2026-08-28-firefox-onepassword-indexeddb-reset.md`: This execution plan. Do not change it during implementation unless the approved behavior changes.

### Planned production interfaces

```python
class ResetError(Exception): ...

@dataclass(frozen=True)
class Options:
    profile_names: tuple[str, ...]
    all_profiles: bool
    yes: bool

@dataclass(frozen=True)
class FirefoxProfile:
    name: str
    path: Path

@dataclass(frozen=True)
class ResetTarget:
    profile: FirefoxProfile
    path: Path
    exists: bool
    size_bytes: int


def parse_args(argv: Sequence[str] | None = None) -> Options: ...
def read_profiles(profiles_ini: Path) -> tuple[FirefoxProfile, ...]: ...
def select_profiles(
    profiles: Sequence[FirefoxProfile], options: Options
) -> tuple[FirefoxProfile, ...]: ...
def parse_1password_uuid(prefs_js: Path) -> str: ...
def directory_size(path: Path) -> int: ...
def build_reset_target(profile: FirefoxProfile) -> ResetTarget: ...
def find_firefox_processes(proc_root: Path) -> tuple[int, ...]: ...
def preflight(
    options: Options,
    *,
    firefox_root: Path,
    proc_root: Path,
    stdin: TextIO,
) -> tuple[ResetTarget, ...]: ...
def show_plan(
    targets: Sequence[ResetTarget], output: Callable[[str], None]
) -> None: ...
def confirm_reset(
    options: Options,
    *,
    stdin: TextIO,
    output: Callable[[str], None],
) -> bool: ...
def remove_targets(
    targets: Sequence[ResetTarget], output: Callable[[str], None]
) -> int: ...
def execute(
    options: Options,
    *,
    firefox_root: Path | None = None,
    proc_root: Path = Path("/proc"),
    stdin: TextIO = sys.stdin,
    output: Callable[[str], None] = print,
) -> int: ...
def main(argv: Sequence[str] | None = None) -> int: ...
```

Later tasks use these names and types exactly.

## Execution Setup

- [ ] **Commit this implementation plan before Task 1**

Run:

```bash
git status --short
git add docs/plans/2026-08-28-firefox-onepassword-indexeddb-reset.md
git commit -m "docs(firefox): plan 1Password IndexedDB reset"
```

Expected: status shows only this plan before the commit. The signed commit contains only this plan, and the worktree becomes clean.

---

### Task 1: Parse selection arguments and discover Firefox profiles

**Files:**
- Create: `scripts/reset-firefox-onepassword-indexeddb.py`
- Create: `scripts/tests/test_reset_firefox_onepassword_indexeddb.py`

**Interfaces:**
- Consumes: CLI argument strings and a Firefox `profiles.ini` path.
- Produces: `ResetError`, `Options`, `FirefoxProfile`, `parse_args`, `read_profiles`, and `select_profiles`.
- Preserves: profile order from `profiles.ini` for `--all`, and argument order for repeated `--profile` selection.

- [ ] **Step 1: Create the test module with failing command-interface tests**

Create `scripts/tests/test_reset_firefox_onepassword_indexeddb.py` with:

```python
from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "reset-firefox-onepassword-indexeddb.py"
SPEC = importlib.util.spec_from_file_location(
    "reset_firefox_onepassword_indexeddb", SCRIPT
)
assert SPEC is not None and SPEC.loader is not None
reset = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = reset
SPEC.loader.exec_module(reset)


def write_profiles_ini(firefox_root: Path, content: str) -> Path:
    profiles_ini = firefox_root / "profiles.ini"
    profiles_ini.write_text(content, encoding="utf-8")
    return profiles_ini


class CommandInterfaceTests(unittest.TestCase):
    def test_parses_repeated_profiles(self) -> None:
        options = reset.parse_args(
            ["--profile", "default", "--profile", "clubhouse"]
        )

        self.assertEqual(options.profile_names, ("default", "clubhouse"))
        self.assertFalse(options.all_profiles)
        self.assertFalse(options.yes)

    def test_parses_all_with_yes(self) -> None:
        options = reset.parse_args(["--all", "--yes"])

        self.assertEqual(options.profile_names, ())
        self.assertTrue(options.all_profiles)
        self.assertTrue(options.yes)

    def test_requires_profile_or_all(self) -> None:
        with mock.patch("sys.stderr", io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                reset.parse_args([])

        self.assertEqual(raised.exception.code, 2)

    def test_rejects_profile_with_all(self) -> None:
        with mock.patch("sys.stderr", io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                reset.parse_args(["--all", "--profile", "default"])

        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the command-interface tests and observe the missing-script error**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py CommandInterfaceTests -v
```

Expected: FAIL during module loading because `scripts/reset-firefox-onepassword-indexeddb.py` does not exist.

- [ ] **Step 3: Add the minimal command parser and data model**

Create `scripts/reset-firefox-onepassword-indexeddb.py` with:

```python
#!/usr/bin/env python3
"""Reset corrupt 1Password IndexedDB data in Firefox profiles."""

from __future__ import annotations

import argparse
import configparser
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path


class ResetError(Exception):
    """A safe Firefox reset cannot continue."""


@dataclass(frozen=True)
class Options:
    profile_names: tuple[str, ...]
    all_profiles: bool
    yes: bool


@dataclass(frozen=True)
class FirefoxProfile:
    name: str
    path: Path


def parse_args(argv: Sequence[str] | None = None) -> Options:
    parser = argparse.ArgumentParser(
        description="Reset 1Password IndexedDB data in Firefox profiles."
    )
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument(
        "--profile",
        action="append",
        dest="profile_names",
        metavar="NAME",
        help="reset one Firefox profile; repeat for more profiles",
    )
    selection.add_argument(
        "--all",
        action="store_true",
        dest="all_profiles",
        help="reset every Firefox profile",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="skip the confirmation prompt",
    )
    parsed = parser.parse_args(argv)
    return Options(
        profile_names=tuple(parsed.profile_names or ()),
        all_profiles=parsed.all_profiles,
        yes=parsed.yes,
    )
```

- [ ] **Step 4: Run the command-interface tests and make sure that they pass**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py CommandInterfaceTests -v
```

Expected: four tests pass.

- [ ] **Step 5: Add failing profile-discovery and selection tests**

Append this class before the `unittest.main()` guard in `scripts/tests/test_reset_firefox_onepassword_indexeddb.py`:

```python
class ProfileDiscoveryTests(unittest.TestCase):
    def test_discovers_relative_and_absolute_profiles(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            firefox_root = Path(directory) / "firefox"
            firefox_root.mkdir()
            relative_profile = firefox_root / "abc.default"
            absolute_profile = Path(directory) / "absolute.clubhouse"
            relative_profile.mkdir()
            absolute_profile.mkdir()
            profiles_ini = write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n"
                "\n"
                "[Profile1]\n"
                "Name=clubhouse\n"
                "IsRelative=0\n"
                f"Path={absolute_profile}\n",
            )

            profiles = reset.read_profiles(profiles_ini)

        self.assertEqual(
            profiles,
            (
                reset.FirefoxProfile("default", relative_profile.resolve()),
                reset.FirefoxProfile("clubhouse", absolute_profile.resolve()),
            ),
        )

    def test_rejects_missing_or_malformed_profile_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            firefox_root = Path(directory)
            with self.assertRaisesRegex(reset.ResetError, "profiles.ini"):
                reset.read_profiles(firefox_root / "missing.ini")

            profiles_ini = write_profiles_ini(
                firefox_root,
                "[Profile0]\nName=default\nIsRelative=1\n",
            )
            with self.assertRaisesRegex(reset.ResetError, "Profile0"):
                reset.read_profiles(profiles_ini)

            write_profiles_ini(firefox_root, "[General]\nStartWithLastProfile=1\n")
            with self.assertRaisesRegex(reset.ResetError, "no Firefox profiles"):
                reset.read_profiles(profiles_ini)

    def test_rejects_invalid_relative_flag_and_duplicate_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            firefox_root = Path(directory)
            profiles_ini = write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=yes\n"
                "Path=abc.default\n",
            )
            with self.assertRaisesRegex(reset.ResetError, "IsRelative"):
                reset.read_profiles(profiles_ini)

            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n"
                "[Profile1]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=def.default\n",
            )
            with self.assertRaisesRegex(reset.ResetError, "duplicate profile"):
                reset.read_profiles(profiles_ini)

    def test_selects_requested_order_and_rejects_unknown_profile(self) -> None:
        profiles = (
            reset.FirefoxProfile("default", Path("/profiles/default")),
            reset.FirefoxProfile("clubhouse", Path("/profiles/clubhouse")),
        )
        selected = reset.select_profiles(
            profiles,
            reset.Options(("clubhouse", "default"), False, False),
        )

        self.assertEqual(
            tuple(profile.name for profile in selected),
            ("clubhouse", "default"),
        )
        self.assertEqual(
            reset.select_profiles(profiles, reset.Options((), True, False)),
            profiles,
        )
        with self.assertRaisesRegex(reset.ResetError, "unknown Firefox profile: missing"):
            reset.select_profiles(
                profiles,
                reset.Options(("missing",), False, False),
            )
```

Keep the existing `unittest.main()` guard at the end of the file.

- [ ] **Step 6: Run the profile tests and observe the missing-interface errors**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py ProfileDiscoveryTests -v
```

Expected: FAIL because `read_profiles` and `select_profiles` do not exist.

- [ ] **Step 7: Implement strict profile discovery and selection**

Append this code to `scripts/reset-firefox-onepassword-indexeddb.py`:

```python
def read_profiles(profiles_ini: Path) -> tuple[FirefoxProfile, ...]:
    configuration = configparser.ConfigParser(interpolation=None)
    try:
        with profiles_ini.open(encoding="utf-8") as stream:
            configuration.read_file(stream)
    except (OSError, UnicodeError, configparser.Error) as error:
        raise ResetError(f"cannot read Firefox profiles.ini: {profiles_ini}") from error

    profiles: list[FirefoxProfile] = []
    names: set[str] = set()
    for section in configuration.sections():
        if not section.startswith("Profile"):
            continue
        values = configuration[section]
        try:
            name = values["Name"].strip()
            relative_flag = values["IsRelative"].strip()
            path_text = values["Path"].strip()
        except KeyError as error:
            raise ResetError(f"malformed Firefox profile section: {section}") from error
        if not name or not path_text:
            raise ResetError(f"malformed Firefox profile section: {section}")
        if relative_flag not in {"0", "1"}:
            raise ResetError(f"invalid IsRelative value in {section}")
        if name in names:
            raise ResetError(f"duplicate profile name: {name}")

        profile_path = Path(path_text).expanduser()
        if relative_flag == "1":
            if profile_path.is_absolute():
                raise ResetError(f"relative profile has an absolute path: {section}")
            profile_path = profiles_ini.parent / profile_path
        elif not profile_path.is_absolute():
            raise ResetError(f"absolute profile has a relative path: {section}")

        names.add(name)
        profiles.append(FirefoxProfile(name, profile_path.resolve(strict=False)))

    if not profiles:
        raise ResetError("profiles.ini contains no Firefox profiles")
    return tuple(profiles)


def select_profiles(
    profiles: Sequence[FirefoxProfile], options: Options
) -> tuple[FirefoxProfile, ...]:
    if options.all_profiles:
        return tuple(profiles)

    profiles_by_name = {profile.name: profile for profile in profiles}
    selected: list[FirefoxProfile] = []
    for name in options.profile_names:
        try:
            selected.append(profiles_by_name[name])
        except KeyError as error:
            raise ResetError(f"unknown Firefox profile: {name}") from error
    return tuple(selected)
```

- [ ] **Step 8: Run the Task 1 tests and make sure that they pass**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py CommandInterfaceTests ProfileDiscoveryTests -v
```

Expected: all Task 1 tests pass.

- [ ] **Step 9: Commit profile selection and discovery**

Run:

```bash
git add scripts/reset-firefox-onepassword-indexeddb.py scripts/tests/test_reset_firefox_onepassword_indexeddb.py
git commit -m "feat(firefox): discover 1Password reset profiles"
```

Expected: one signed Conventional Commit that contains only the two script paths.

---

### Task 2: Parse the 1Password UUID and build safe reset targets

**Files:**
- Modify: `scripts/reset-firefox-onepassword-indexeddb.py`
- Modify: `scripts/tests/test_reset_firefox_onepassword_indexeddb.py`

**Interfaces:**
- Consumes: `FirefoxProfile`, `prefs.js`, and the 1Password extension ID `{d634138d-c276-4fc8-924b-40a0ea21d284}`.
- Produces: `ResetTarget`, `parse_1password_uuid`, `directory_size`, and `build_reset_target`.
- Rejects: missing files, malformed nested JSON, malformed or missing UUIDs, non-directory targets, path escapes, direct `idb` symlinks, and escaping parent symlinks.

- [ ] **Step 1: Add JSON and synthetic preference helpers to the tests**

Add this import with the test imports:

```python
import json
```

Add this helper below `write_profiles_ini`:

```python
def write_uuid_pref(profile: Path, mapping: dict[str, str]) -> Path:
    prefs_js = profile / "prefs.js"
    nested_json = json.dumps(mapping)
    prefs_js.write_text(
        "user_pref(\"extensions.webextensions.uuids\", "
        f"{json.dumps(nested_json)});\n",
        encoding="utf-8",
    )
    return prefs_js
```

- [ ] **Step 2: Add failing UUID parsing tests**

Add this class before the test-file guard:

```python
class OnePasswordTargetTests(unittest.TestCase):
    EXTENSION_ID = "{d634138d-c276-4fc8-924b-40a0ea21d284}"
    UUID = "11111111-2222-4333-8444-555555555555"

    def test_parses_nested_uuid_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            prefs_js = write_uuid_pref(
                profile,
                {
                    "other@example.test": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                    self.EXTENSION_ID: self.UUID,
                },
            )

            extension_uuid = reset.parse_1password_uuid(prefs_js)

        self.assertEqual(extension_uuid, self.UUID)

    def test_rejects_missing_or_malformed_uuid_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            with self.assertRaisesRegex(reset.ResetError, "prefs.js"):
                reset.parse_1password_uuid(profile / "prefs.js")

            prefs_js = profile / "prefs.js"
            prefs_js.write_text(
                'user_pref("browser.startup.page", 1);\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(reset.ResetError, "UUID preference"):
                reset.parse_1password_uuid(prefs_js)

            prefs_js.write_text(
                'user_pref("extensions.webextensions.uuids", "{not-json}");\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(reset.ResetError, "malformed UUID preference"):
                reset.parse_1password_uuid(prefs_js)

    def test_rejects_missing_or_malformed_onepassword_uuid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            prefs_js = write_uuid_pref(
                profile,
                {"other@example.test": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"},
            )
            with self.assertRaisesRegex(reset.ResetError, "1Password UUID"):
                reset.parse_1password_uuid(prefs_js)

            prefs_js = write_uuid_pref(
                profile,
                {self.EXTENSION_ID: "not-a-uuid"},
            )
            with self.assertRaisesRegex(reset.ResetError, "malformed 1Password UUID"):
                reset.parse_1password_uuid(prefs_js)
```

- [ ] **Step 3: Run the UUID tests and observe the missing-function errors**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py OnePasswordTargetTests -v
```

Expected: FAIL because `parse_1password_uuid` does not exist.

- [ ] **Step 4: Implement nested JSON parsing without evaluating JavaScript**

Add these imports to `scripts/reset-firefox-onepassword-indexeddb.py`:

```python
import json
import os
import re
from uuid import UUID
```

Add these constants after the imports:

```python
ONEPASSWORD_EXTENSION_ID = "{d634138d-c276-4fc8-924b-40a0ea21d284}"
UUID_PREFERENCE_PATTERN = re.compile(
    r'^user_pref\("extensions\.webextensions\.uuids",\s*'
    r'(?P<encoded>"(?:\\.|[^"\\])*")\s*\);\s*$',
    re.MULTILINE,
)
```

Add this function after `select_profiles`:

```python
def parse_1password_uuid(prefs_js: Path) -> str:
    try:
        prefs_text = prefs_js.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ResetError(f"cannot read Firefox prefs.js: {prefs_js}") from error

    matches = tuple(UUID_PREFERENCE_PATTERN.finditer(prefs_text))
    if not matches:
        raise ResetError(f"missing UUID preference in {prefs_js}")
    try:
        nested_json = json.loads(matches[-1].group("encoded"))
        uuid_mapping = json.loads(nested_json)
    except (json.JSONDecodeError, TypeError) as error:
        raise ResetError(f"malformed UUID preference in {prefs_js}") from error
    if not isinstance(uuid_mapping, dict):
        raise ResetError(f"malformed UUID preference in {prefs_js}")

    extension_uuid = uuid_mapping.get(ONEPASSWORD_EXTENSION_ID)
    if not isinstance(extension_uuid, str) or not extension_uuid:
        raise ResetError(f"profile has no registered 1Password UUID: {prefs_js.parent}")
    try:
        parsed_uuid = UUID(extension_uuid)
    except (ValueError, AttributeError) as error:
        raise ResetError(f"malformed 1Password UUID in {prefs_js}") from error
    if str(parsed_uuid) != extension_uuid.lower():
        raise ResetError(f"malformed 1Password UUID in {prefs_js}")
    return extension_uuid
```

- [ ] **Step 5: Run the UUID tests and make sure that they pass**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py OnePasswordTargetTests -v
```

Expected: the three UUID tests pass.

- [ ] **Step 6: Add failing exact-path, size, and target-type tests**

Append these methods to `OnePasswordTargetTests`:

```python
    def test_builds_exact_reset_path_and_counts_file_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile_path = Path(directory) / "profile"
            profile_path.mkdir()
            write_uuid_pref(profile_path, {self.EXTENSION_ID: self.UUID})
            expected = (
                profile_path
                / "storage"
                / "default"
                / f"moz-extension+++{self.UUID}"
                / "idb"
            )
            (expected / "nested").mkdir(parents=True)
            (expected / "data.sqlite").write_bytes(b"1234")
            (expected / "nested" / "metadata").write_bytes(b"56")
            (expected.parent / "storage.js").write_text("keep", encoding="utf-8")

            target = reset.build_reset_target(
                reset.FirefoxProfile("default", profile_path)
            )

        self.assertEqual(target.profile.name, "default")
        self.assertEqual(target.path, expected)
        self.assertTrue(target.exists)
        self.assertEqual(target.size_bytes, 6)

    def test_builds_absent_target_as_zero_byte_noop(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile_path = Path(directory) / "profile"
            profile_path.mkdir()
            write_uuid_pref(profile_path, {self.EXTENSION_ID: self.UUID})

            target = reset.build_reset_target(
                reset.FirefoxProfile("default", profile_path)
            )

        self.assertFalse(target.exists)
        self.assertEqual(target.size_bytes, 0)

    def test_rejects_missing_profile_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile_path = Path(directory) / "missing-profile"

            with self.assertRaisesRegex(reset.ResetError, "does not exist"):
                reset.build_reset_target(
                    reset.FirefoxProfile("default", profile_path)
                )

    def test_rejects_reset_target_that_is_not_a_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile_path = Path(directory) / "profile"
            profile_path.mkdir()
            write_uuid_pref(profile_path, {self.EXTENSION_ID: self.UUID})
            target = (
                profile_path
                / "storage"
                / "default"
                / f"moz-extension+++{self.UUID}"
                / "idb"
            )
            target.parent.mkdir(parents=True)
            target.write_text("not a directory", encoding="utf-8")

            with self.assertRaisesRegex(reset.ResetError, "not a directory"):
                reset.build_reset_target(
                    reset.FirefoxProfile("default", profile_path)
                )
```

- [ ] **Step 7: Add failing escape and symbolic-link tests**

Append these methods to `OnePasswordTargetTests`:

```python
    def test_rejects_uuid_path_that_escapes_the_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile_path = Path(directory) / "profile"
            profile_path.mkdir()
            with mock.patch.object(
                reset,
                "parse_1password_uuid",
                return_value="x/../../../../outside",
            ):
                with self.assertRaisesRegex(
                    reset.ResetError, "escapes Firefox profile"
                ):
                    reset.build_reset_target(
                        reset.FirefoxProfile("default", profile_path)
                    )

    def test_rejects_direct_symbolic_link_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile_path = Path(directory) / "profile"
            profile_path.mkdir()
            write_uuid_pref(profile_path, {self.EXTENSION_ID: self.UUID})
            safe_destination = profile_path / "other-idb"
            safe_destination.mkdir()
            target = (
                profile_path
                / "storage"
                / "default"
                / f"moz-extension+++{self.UUID}"
                / "idb"
            )
            target.parent.mkdir(parents=True)
            target.symlink_to(safe_destination, target_is_directory=True)

            with self.assertRaisesRegex(reset.ResetError, "symbolic link"):
                reset.build_reset_target(
                    reset.FirefoxProfile("default", profile_path)
                )

    def test_rejects_parent_symbolic_link_that_escapes_the_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile_path = root / "profile"
            profile_path.mkdir()
            write_uuid_pref(profile_path, {self.EXTENSION_ID: self.UUID})
            outside_origin = root / "outside-origin"
            (outside_origin / "idb").mkdir(parents=True)
            storage_default = profile_path / "storage" / "default"
            storage_default.mkdir(parents=True)
            origin = storage_default / f"moz-extension+++{self.UUID}"
            origin.symlink_to(outside_origin, target_is_directory=True)

            with self.assertRaisesRegex(reset.ResetError, "escapes Firefox profile"):
                reset.build_reset_target(
                    reset.FirefoxProfile("default", profile_path)
                )
```

- [ ] **Step 8: Run the new target tests and observe the missing-interface errors**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py OnePasswordTargetTests -v
```

Expected: the UUID tests pass. The target tests fail because `ResetTarget` and `build_reset_target` do not exist.

- [ ] **Step 9: Implement safe target construction and byte counting**

Add this data class after `FirefoxProfile`:

```python
@dataclass(frozen=True)
class ResetTarget:
    profile: FirefoxProfile
    path: Path
    exists: bool
    size_bytes: int
```

Add these functions after `parse_1password_uuid`:

```python
def directory_size(path: Path) -> int:
    total = 0
    try:
        for root, _directories, files in os.walk(path, followlinks=False):
            root_path = Path(root)
            for name in files:
                total += (root_path / name).stat(follow_symlinks=False).st_size
    except OSError as error:
        raise ResetError(f"cannot inspect reset path: {path}") from error
    return total


def build_reset_target(profile: FirefoxProfile) -> ResetTarget:
    if not profile.path.is_dir():
        raise ResetError(f"Firefox profile directory does not exist: {profile.name}")
    profile_root = profile.path.resolve()
    extension_uuid = parse_1password_uuid(profile_root / "prefs.js")
    candidate = (
        profile_root
        / "storage"
        / "default"
        / f"moz-extension+++{extension_uuid}"
        / "idb"
    )
    if candidate.is_symlink():
        raise ResetError(f"reset path is a symbolic link: {candidate}")

    resolved_candidate = candidate.resolve(strict=False)
    try:
        resolved_candidate.relative_to(profile_root)
    except ValueError as error:
        raise ResetError(
            f"reset path escapes Firefox profile {profile.name}: {candidate}"
        ) from error

    exists = candidate.exists()
    if exists and not candidate.is_dir():
        raise ResetError(f"reset path is not a directory: {candidate}")
    return ResetTarget(
        profile=profile,
        path=candidate,
        exists=exists,
        size_bytes=directory_size(candidate) if exists else 0,
    )
```

- [ ] **Step 10: Run all Task 2 tests and make sure that they pass**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py OnePasswordTargetTests -v
```

Expected: all UUID, exact-path, no-op, type, escape, and symbolic-link tests pass.

- [ ] **Step 11: Commit UUID parsing and target safety**

Run:

```bash
git add scripts/reset-firefox-onepassword-indexeddb.py scripts/tests/test_reset_firefox_onepassword_indexeddb.py
git commit -m "feat(firefox): validate 1Password reset targets"
```

Expected: one signed commit with the target model, parser, safety checks, and their tests.

---

### Task 3: Detect Firefox and complete all preflight checks

**Files:**
- Modify: `scripts/reset-firefox-onepassword-indexeddb.py`
- Modify: `scripts/tests/test_reset_firefox_onepassword_indexeddb.py`

**Interfaces:**
- Consumes: a synthetic or real `/proc` root, `Options`, a Firefox root, and an input stream.
- Produces: `find_firefox_processes` and `preflight`.
- Guarantees: `preflight` returns every validated target or raises `ResetError`. It does not remove data.

- [ ] **Step 1: Add a synthetic process helper and failing process tests**

Add this helper below `write_uuid_pref`:

```python
def write_process(proc_root: Path, pid: int, command: str) -> None:
    process = proc_root / str(pid)
    process.mkdir()
    (process / "comm").write_text(f"{command}\n", encoding="utf-8")
```

Add this class before the test-file guard:

```python
class PreflightTests(unittest.TestCase):
    EXTENSION_ID = "{d634138d-c276-4fc8-924b-40a0ea21d284}"
    UUID = "11111111-2222-4333-8444-555555555555"

    def test_finds_firefox_and_firefox_bin_processes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)
            write_process(proc_root, 31, "firefox")
            write_process(proc_root, 45, "firefox-bin")
            write_process(proc_root, 52, "Web Content")

            processes = reset.find_firefox_processes(proc_root)

        self.assertEqual(processes, (31, 45))

    def test_ignores_non_process_and_disappeared_process_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)
            (proc_root / "self").mkdir()
            (proc_root / "99").mkdir()
            write_process(proc_root, 100, "python3")

            processes = reset.find_firefox_processes(proc_root)

        self.assertEqual(processes, ())
```

- [ ] **Step 2: Run the process tests and observe the missing-function errors**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py PreflightTests -v
```

Expected: FAIL because `find_firefox_processes` does not exist.

- [ ] **Step 3: Implement fail-closed Linux process inspection**

Append this function to `scripts/reset-firefox-onepassword-indexeddb.py`:

```python
def find_firefox_processes(proc_root: Path) -> tuple[int, ...]:
    try:
        process_entries = tuple(proc_root.iterdir())
    except OSError as error:
        raise ResetError("cannot inspect Linux process data") from error

    firefox_processes: list[int] = []
    for process in process_entries:
        if not process.name.isdigit():
            continue
        try:
            command = (process / "comm").read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            continue
        except (OSError, UnicodeError) as error:
            raise ResetError("cannot inspect Linux process data") from error
        if command in {"firefox", "firefox-bin"}:
            firefox_processes.append(int(process.name))
    return tuple(sorted(firefox_processes))
```

- [ ] **Step 4: Run the process tests and make sure that they pass**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py PreflightTests -v
```

Expected: the two process tests pass.

- [ ] **Step 5: Add failing preflight tests**

Append these methods to `PreflightTests`:

```python
    def test_refuses_preflight_while_firefox_is_active(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proc_root = root / "proc"
            proc_root.mkdir()
            write_process(proc_root, 31, "firefox")

            with self.assertRaisesRegex(reset.ResetError, "Firefox is active"):
                reset.preflight(
                    reset.Options((), True, True),
                    firefox_root=root / "firefox",
                    proc_root=proc_root,
                    stdin=io.StringIO(),
                )

    def test_noninteractive_preflight_requires_yes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proc_root = root / "proc"
            proc_root.mkdir()

            with self.assertRaisesRegex(reset.ResetError, "use --yes"):
                reset.preflight(
                    reset.Options(("default",), False, False),
                    firefox_root=root / "firefox",
                    proc_root=proc_root,
                    stdin=io.StringIO(),
                )

    def test_preflight_resolves_every_selected_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            firefox_root = root / "firefox"
            firefox_root.mkdir()
            proc_root = root / "proc"
            proc_root.mkdir()
            default_profile = firefox_root / "abc.default"
            clubhouse_profile = firefox_root / "def.clubhouse"
            default_profile.mkdir()
            clubhouse_profile.mkdir()
            write_uuid_pref(default_profile, {self.EXTENSION_ID: self.UUID})
            write_uuid_pref(
                clubhouse_profile,
                {
                    self.EXTENSION_ID:
                    "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
                },
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n"
                "[Profile1]\n"
                "Name=clubhouse\n"
                "IsRelative=1\n"
                "Path=def.clubhouse\n",
            )

            targets = reset.preflight(
                reset.Options((), True, True),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=io.StringIO(),
            )

        self.assertEqual(
            tuple(target.profile.name for target in targets),
            ("default", "clubhouse"),
        )
        self.assertTrue(all(target.path.name == "idb" for target in targets))
```

- [ ] **Step 6: Run the new preflight tests and observe the missing-function errors**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py PreflightTests -v
```

Expected: the process tests pass. The three preflight tests fail because `preflight` does not exist.

- [ ] **Step 7: Implement ordered, non-destructive preflight**

Add this import to `scripts/reset-firefox-onepassword-indexeddb.py`:

```python
from typing import TextIO
```

Append this function:

```python
def preflight(
    options: Options,
    *,
    firefox_root: Path,
    proc_root: Path,
    stdin: TextIO,
) -> tuple[ResetTarget, ...]:
    active_processes = find_firefox_processes(proc_root)
    if active_processes:
        raise ResetError("Firefox is active; close Firefox before the reset")
    if not options.yes and not stdin.isatty():
        raise ResetError("standard input is not interactive; use --yes")

    profiles = read_profiles(firefox_root / "profiles.ini")
    selected_profiles = select_profiles(profiles, options)
    return tuple(build_reset_target(profile) for profile in selected_profiles)
```

The tuple construction must finish before `execute` calls any removal function. Do not add a removal call to `preflight`.

- [ ] **Step 8: Run all preflight tests and make sure that they pass**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py PreflightTests -v
```

Expected: all process and preflight tests pass.

- [ ] **Step 9: Commit the preflight boundary**

Run:

```bash
git add scripts/reset-firefox-onepassword-indexeddb.py scripts/tests/test_reset_firefox_onepassword_indexeddb.py
git commit -m "feat(firefox): add safe reset preflight"
```

Expected: one signed commit that contains process inspection and non-destructive preflight.

---

### Task 4: Show the complete plan and obtain one confirmation

**Files:**
- Modify: `scripts/reset-firefox-onepassword-indexeddb.py`
- Modify: `scripts/tests/test_reset_firefox_onepassword_indexeddb.py`

**Interfaces:**
- Consumes: the complete `ResetTarget` tuple, `Options`, an input stream, and an output callback.
- Produces: `show_plan` and `confirm_reset`.
- Output contract: one `PLAN` line per selected profile, followed by one prompt unless `--yes` is active.

- [ ] **Step 1: Add failing preview and confirmation tests**

Add this class before the test-file guard:

```python
class ConfirmationTests(unittest.TestCase):
    def test_show_plan_lists_each_profile_path_size_and_state(self) -> None:
        targets = (
            reset.ResetTarget(
                reset.FirefoxProfile("default", Path("/profiles/default")),
                Path("/profiles/default/storage/default/origin/idb"),
                True,
                6,
            ),
            reset.ResetTarget(
                reset.FirefoxProfile("clubhouse", Path("/profiles/clubhouse")),
                Path("/profiles/clubhouse/storage/default/origin/idb"),
                False,
                0,
            ),
        )
        output: list[str] = []

        reset.show_plan(targets, output.append)

        self.assertEqual(
            output,
            [
                "Reset plan:",
                "PLAN default: "
                "/profiles/default/storage/default/origin/idb "
                "(6 bytes; present)",
                "PLAN clubhouse: "
                "/profiles/clubhouse/storage/default/origin/idb "
                "(0 bytes; absent)",
            ],
        )

    def test_confirmation_defaults_to_no(self) -> None:
        for answer in ("", "\n", "n\n", "anything\n"):
            with self.subTest(answer=answer):
                output: list[str] = []
                confirmed = reset.confirm_reset(
                    reset.Options(("default",), False, False),
                    stdin=io.StringIO(answer),
                    output=output.append,
                )
                self.assertFalse(confirmed)
                self.assertEqual(output, ["Continue with this reset? [y/N]"])

    def test_confirmation_accepts_y_or_yes(self) -> None:
        for answer in ("y\n", "Y\n", "yes\n", "YES\n"):
            with self.subTest(answer=answer):
                confirmed = reset.confirm_reset(
                    reset.Options(("default",), False, False),
                    stdin=io.StringIO(answer),
                    output=lambda _line: None,
                )
                self.assertTrue(confirmed)

    def test_yes_skips_the_prompt_and_input_read(self) -> None:
        stdin = mock.Mock()
        output: list[str] = []

        confirmed = reset.confirm_reset(
            reset.Options((), True, True),
            stdin=stdin,
            output=output.append,
        )

        self.assertTrue(confirmed)
        stdin.readline.assert_not_called()
        self.assertEqual(output, [])
```

- [ ] **Step 2: Run the confirmation tests and observe the missing-function errors**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py ConfirmationTests -v
```

Expected: FAIL because `show_plan` and `confirm_reset` do not exist.

- [ ] **Step 3: Implement deterministic preview and default-No confirmation**

Add this import to `scripts/reset-firefox-onepassword-indexeddb.py`:

```python
from collections.abc import Callable, Sequence
```

Replace the existing `Sequence`-only import with the combined import above. Then append:

```python
def show_plan(
    targets: Sequence[ResetTarget], output: Callable[[str], None]
) -> None:
    output("Reset plan:")
    for target in targets:
        state = "present" if target.exists else "absent"
        output(
            f"PLAN {target.profile.name}: {target.path} "
            f"({target.size_bytes} bytes; {state})"
        )


def confirm_reset(
    options: Options,
    *,
    stdin: TextIO,
    output: Callable[[str], None],
) -> bool:
    if options.yes:
        return True
    output("Continue with this reset? [y/N]")
    return stdin.readline().strip().lower() in {"y", "yes"}
```

- [ ] **Step 4: Run the confirmation tests and make sure that they pass**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py ConfirmationTests -v
```

Expected: all preview, default-No, affirmative, and `--yes` tests pass.

- [ ] **Step 5: Commit preview and confirmation behavior**

Run:

```bash
git add scripts/reset-firefox-onepassword-indexeddb.py scripts/tests/test_reset_firefox_onepassword_indexeddb.py
git commit -m "feat(firefox): preview 1Password reset targets"
```

Expected: one signed commit that adds only the preview and confirmation layer.

---

### Task 5: Remove only validated IndexedDB directories and report results

**Files:**
- Modify: `scripts/reset-firefox-onepassword-indexeddb.py`
- Modify: `scripts/tests/test_reset_firefox_onepassword_indexeddb.py`

**Interfaces:**
- Consumes: validated targets from `preflight`.
- Produces: `remove_targets`, `execute`, `main`, and the executable CLI guard.
- Result contract: `RESET`, `SKIP`, `ERROR`, or `CANCELLED` identifies each completed profile result.
- Exit contract: return `0` for reset, no-op, or cancellation. Return `2` for preflight or removal errors.

- [ ] **Step 1: Add reusable execution fixtures to the tests**

Add this helper below `write_process`:

```python
def create_firefox_profile(
    firefox_root: Path,
    relative_path: str,
    extension_uuid: str,
    *,
    idb_files: dict[str, bytes] | None = None,
) -> tuple[Path, Path]:
    profile = firefox_root / relative_path
    profile.mkdir(parents=True)
    write_uuid_pref(
        profile,
        {
            "{d634138d-c276-4fc8-924b-40a0ea21d284}": extension_uuid,
        },
    )
    target = (
        profile
        / "storage"
        / "default"
        / f"moz-extension+++{extension_uuid}"
        / "idb"
    )
    if idb_files is not None:
        target.mkdir(parents=True)
        for relative_name, content in idb_files.items():
            destination = target / relative_name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
    return profile, target


class InteractiveInput(io.StringIO):
    def isatty(self) -> bool:
        return True
```

- [ ] **Step 2: Add failing cancellation, selected-profile, and no-op tests**

Add this class before the test-file guard:

```python
class ExecutionTests(unittest.TestCase):
    DEFAULT_UUID = "11111111-2222-4333-8444-555555555555"
    CLUBHOUSE_UUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    def test_cancellation_returns_zero_without_removing_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            firefox_root = root / "firefox"
            firefox_root.mkdir()
            proc_root = root / "proc"
            proc_root.mkdir()
            _profile, target = create_firefox_profile(
                firefox_root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"data.sqlite": b"data"},
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )
            output: list[str] = []

            result = reset.execute(
                reset.Options(("default",), False, False),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=InteractiveInput("\n"),
                output=output.append,
            )

            self.assertTrue(target.is_dir())
        self.assertEqual(result, 0)
        self.assertTrue(any(line.startswith("PLAN default:") for line in output))
        self.assertTrue(any(line.startswith("CANCELLED default:") for line in output))
        self.assertFalse(any(line.startswith("RESET ") for line in output))

    def test_yes_removes_only_selected_idb_and_preserves_other_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            firefox_root = root / "firefox"
            firefox_root.mkdir()
            proc_root = root / "proc"
            proc_root.mkdir()
            default_profile, default_target = create_firefox_profile(
                firefox_root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"data.sqlite": b"default-data"},
            )
            _clubhouse_profile, clubhouse_target = create_firefox_profile(
                firefox_root,
                "def.clubhouse",
                self.CLUBHOUSE_UUID,
                idb_files={"data.sqlite": b"clubhouse-data"},
            )
            storage_js = default_target.parent / "storage.js"
            storage_js.write_text("keep", encoding="utf-8")
            profile_file = default_profile / "places.sqlite"
            profile_file.write_bytes(b"keep")
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n"
                "[Profile1]\n"
                "Name=clubhouse\n"
                "IsRelative=1\n"
                "Path=def.clubhouse\n",
            )
            output: list[str] = []

            result = reset.execute(
                reset.Options(("default",), False, True),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=io.StringIO(),
                output=output.append,
            )

            self.assertFalse(default_target.exists())
            self.assertTrue(clubhouse_target.is_dir())
            self.assertTrue(storage_js.is_file())
            self.assertTrue(profile_file.is_file())
        self.assertEqual(result, 0)
        self.assertTrue(any(line.startswith("RESET default:") for line in output))
        self.assertFalse(any("clubhouse" in line for line in output))
        self.assertEqual(
            output[-1],
            "Start Firefox and reconnect 1Password if necessary.",
        )

    def test_absent_idb_reports_skip_and_returns_zero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            firefox_root = root / "firefox"
            firefox_root.mkdir()
            proc_root = root / "proc"
            proc_root.mkdir()
            create_firefox_profile(
                firefox_root,
                "abc.default",
                self.DEFAULT_UUID,
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )
            output: list[str] = []

            result = reset.execute(
                reset.Options(("default",), False, True),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=io.StringIO(),
                output=output.append,
            )

        self.assertEqual(result, 0)
        self.assertTrue(any(line.startswith("SKIP default:") for line in output))
```

- [ ] **Step 3: Add failing `--all`, all-or-nothing, and sanitized-error tests**

Append these methods to `ExecutionTests`:

```python
    def test_all_removes_each_selected_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            firefox_root = root / "firefox"
            firefox_root.mkdir()
            proc_root = root / "proc"
            proc_root.mkdir()
            _default_profile, default_target = create_firefox_profile(
                firefox_root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"data.sqlite": b"default"},
            )
            _clubhouse_profile, clubhouse_target = create_firefox_profile(
                firefox_root,
                "def.clubhouse",
                self.CLUBHOUSE_UUID,
                idb_files={"data.sqlite": b"clubhouse"},
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n"
                "[Profile1]\n"
                "Name=clubhouse\n"
                "IsRelative=1\n"
                "Path=def.clubhouse\n",
            )
            output: list[str] = []

            result = reset.execute(
                reset.Options((), True, True),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=io.StringIO(),
                output=output.append,
            )

            self.assertFalse(default_target.exists())
            self.assertFalse(clubhouse_target.exists())
        self.assertEqual(result, 0)
        self.assertEqual(
            sum(line.startswith("RESET ") for line in output),
            2,
        )

    def test_preflight_failure_preserves_every_valid_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            firefox_root = root / "firefox"
            firefox_root.mkdir()
            proc_root = root / "proc"
            proc_root.mkdir()
            _valid_profile, valid_target = create_firefox_profile(
                firefox_root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"data.sqlite": b"keep"},
            )
            broken_profile = firefox_root / "def.broken"
            broken_profile.mkdir()
            write_uuid_pref(
                broken_profile,
                {"other@example.test": self.CLUBHOUSE_UUID},
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n"
                "[Profile1]\n"
                "Name=broken\n"
                "IsRelative=1\n"
                "Path=def.broken\n",
            )
            output: list[str] = []

            result = reset.execute(
                reset.Options((), True, True),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=io.StringIO(),
                output=output.append,
            )

            self.assertTrue(valid_target.is_dir())
        self.assertEqual(result, 2)
        self.assertTrue(output[0].startswith("ERROR:"))
        self.assertFalse(
            any(
                line.startswith(("PLAN ", "RESET ", "SKIP ", "CANCELLED "))
                for line in output
            )
        )

    def test_removal_error_is_sanitized_and_returns_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            firefox_root = root / "firefox"
            firefox_root.mkdir()
            proc_root = root / "proc"
            proc_root.mkdir()
            _profile, target = create_firefox_profile(
                firefox_root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"secret-child-name.sqlite": b"data"},
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )
            output: list[str] = []
            with mock.patch.object(
                reset.shutil,
                "rmtree",
                side_effect=OSError("secret-child-name.sqlite"),
            ):
                result = reset.execute(
                    reset.Options(("default",), False, True),
                    firefox_root=firefox_root,
                    proc_root=proc_root,
                    stdin=io.StringIO(),
                    output=output.append,
                )

            self.assertTrue(target.is_dir())
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR default:") for line in output))
        self.assertNotIn("secret-child-name.sqlite", "\n".join(output))
        self.assertNotEqual(
            output[-1],
            "Start Firefox and reconnect 1Password if necessary.",
        )
```

- [ ] **Step 4: Run the execution tests and observe the missing-interface errors**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py ExecutionTests -v
```

Expected: FAIL because `execute` and `remove_targets` do not exist.

- [ ] **Step 5: Implement controlled removal and the command flow**

Add these imports to `scripts/reset-firefox-onepassword-indexeddb.py`:

```python
import shutil
import sys
```

Append this code:

```python
def remove_targets(
    targets: Sequence[ResetTarget], output: Callable[[str], None]
) -> int:
    failed = False
    for target in targets:
        if not target.path.exists():
            output(f"SKIP {target.profile.name}: {target.path}")
            continue
        try:
            shutil.rmtree(target.path)
        except OSError:
            output(
                f"ERROR {target.profile.name}: could not remove {target.path}"
            )
            failed = True
        else:
            output(f"RESET {target.profile.name}: {target.path}")
    return 2 if failed else 0


def execute(
    options: Options,
    *,
    firefox_root: Path | None = None,
    proc_root: Path = Path("/proc"),
    stdin: TextIO = sys.stdin,
    output: Callable[[str], None] = print,
) -> int:
    selected_firefox_root = (
        firefox_root
        if firefox_root is not None
        else Path.home() / ".mozilla" / "firefox"
    )
    try:
        targets = preflight(
            options,
            firefox_root=selected_firefox_root,
            proc_root=proc_root,
            stdin=stdin,
        )
    except ResetError as error:
        output(f"ERROR: {error}")
        return 2

    show_plan(targets, output)
    if not confirm_reset(options, stdin=stdin, output=output):
        for target in targets:
            output(f"CANCELLED {target.profile.name}: {target.path}")
        return 0

    result = remove_targets(targets, output)
    if result == 0:
        output("Start Firefox and reconnect 1Password if necessary.")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    return execute(parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
```

Do not add `subprocess`, `os.system`, an `exec` function, or a Firefox launch.

- [ ] **Step 6: Run the focused execution tests and make sure that they pass**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py ExecutionTests -v
```

Expected: all cancellation, selected-profile, `--all`, no-op, all-or-nothing, and removal-error tests pass.

- [ ] **Step 7: Run the complete new test module**

Run:

```bash
python3 scripts/tests/test_reset_firefox_onepassword_indexeddb.py -v
```

Expected: every test in the new module passes.

- [ ] **Step 8: Make the script executable and inspect its command interface**

Run:

```bash
chmod +x scripts/reset-firefox-onepassword-indexeddb.py
python3 -m py_compile scripts/reset-firefox-onepassword-indexeddb.py scripts/tests/test_reset_firefox_onepassword_indexeddb.py
python3 -I scripts/reset-firefox-onepassword-indexeddb.py --help
```

Expected: compilation exits `0`. Help exits `0` and shows `--profile`, `--all`, and `--yes`.

- [ ] **Step 9: Run the complete repository script test suite**

Run:

```bash
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

Expected: all 30 baseline tests and all new tests pass.

- [ ] **Step 10: Make sure that the script contains no process-launch API**

Run:

```bash
python3 - <<'PY'
import ast
from pathlib import Path

path = Path("scripts/reset-firefox-onepassword-indexeddb.py")
tree = ast.parse(path.read_text(encoding="utf-8"))
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        names = (
            [alias.name for alias in node.names]
            if isinstance(node, ast.Import)
            else [node.module or ""]
        )
        if any(name == "subprocess" or name.startswith("subprocess.") for name in names):
            raise SystemExit("subprocess import found")
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        if node.func.attr in {"system", "popen", "spawnl", "spawnlp", "spawnv", "spawnvp"}:
            raise SystemExit(f"process-launch call found: {node.func.attr}")
print("no process-launch API found")
PY
```

Expected: exit `0` and `no process-launch API found`.

This direct check replaces a source-text unit test because the property is static.

- [ ] **Step 11: Inspect formatting errors and the implementation diff**

Run:

```bash
git diff --check
git status --short
git diff -- scripts/reset-firefox-onepassword-indexeddb.py scripts/tests/test_reset_firefox_onepassword_indexeddb.py
```

Expected: `git diff --check` exits `0`. Status shows only the two planned script paths before the commit.

Inspect the diff and make sure that each removal path ends in `/idb`. Make sure that no output includes a child path below `/idb`.

- [ ] **Step 12: Commit the completed recovery command**

Run:

```bash
git add scripts/reset-firefox-onepassword-indexeddb.py scripts/tests/test_reset_firefox_onepassword_indexeddb.py
git commit -m "feat(firefox): reset 1Password IndexedDB data"
```

Expected: one signed Conventional Commit with the executable script and complete test coverage.

- [ ] **Step 13: Run final verification from the committed tree**

Run:

```bash
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 -I scripts/reset-firefox-onepassword-indexeddb.py --help >/dev/null
git diff --check HEAD^
git status --short
```

Expected: all tests pass. The help check exits `0`. The diff check exits `0`. Worktree status has no output.
