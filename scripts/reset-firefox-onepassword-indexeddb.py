#!/usr/bin/env python3
"""Reset corrupt 1Password IndexedDB data in Firefox profiles.

This remains one executable for drop-in use and auditability. Sections separate
profile discovery, target validation, preflight, presentation, and removal.
"""

from __future__ import annotations

import argparse
import configparser
import errno
import json
import os
import re
import secrets
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO
from uuid import UUID

# Constants and data model

ONEPASSWORD_EXTENSION_ID = "{d634138d-c276-4fc8-924b-40a0ea21d284}"
UUID_PREFERENCE_PATTERN = re.compile(
    r'^user_pref\("extensions\.webextensions\.uuids",\s*'
    r'(?P<encoded>"(?:\\.|[^"\\])*")\s*\);\s*$',
    re.MULTILINE,
)
MOUNT_ID_PATTERN = re.compile(r"^mnt_id:\s*(?P<mount_id>\d+)\s*$", re.MULTILINE)


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


@dataclass(frozen=True)
class ResetTarget:
    profile: FirefoxProfile
    path: Path
    exists: bool
    size_bytes: int
    origin_identity: tuple[int, int] | None = None
    idb_identity: tuple[int, int] | None = None


@dataclass(frozen=True)
class PreparedResetTarget:
    target: ResetTarget
    report_targets: tuple[ResetTarget, ...]
    origin_fd: int | None
    idb_fd: int | None


# CLI and Firefox profile discovery


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
    selected_names: set[str] = set()
    for name in options.profile_names:
        try:
            profile = profiles_by_name[name]
        except KeyError as error:
            raise ResetError(f"unknown Firefox profile: {name}") from error
        if name not in selected_names:
            selected.append(profile)
            selected_names.add(name)
    return tuple(selected)


# 1Password UUID parsing and reset-target validation


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


def directory_size(path: Path) -> int:
    def raise_walk_error(error: OSError) -> None:
        raise error

    total = 0
    try:
        for root, _directories, files in os.walk(
            path,
            followlinks=False,
            onerror=raise_walk_error,
        ):
            root_path = Path(root)
            for name in files:
                total += (root_path / name).stat(follow_symlinks=False).st_size
    except OSError as error:
        raise ResetError(f"cannot inspect reset path: {path}") from error
    return total


def _mount_id(directory_fd: int, *, proc_root: Path = Path("/proc")) -> int:
    fdinfo_path = proc_root / "self" / "fdinfo" / str(directory_fd)
    try:
        fdinfo = fdinfo_path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise ResetError("cannot inspect reset path mount") from error
    match = MOUNT_ID_PATTERN.search(fdinfo)
    if match is None:
        raise ResetError("cannot inspect reset path mount")
    return int(match.group("mount_id"))


def _directory_open_flags() -> int:
    return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _open_origin_directory(profile_path: Path, origin_name: str) -> int:
    current_fd = os.open(profile_path, _directory_open_flags())
    try:
        for component in ("storage", "default", origin_name):
            next_fd = os.open(
                component,
                _directory_open_flags(),
                dir_fd=current_fd,
            )
            os.close(current_fd)
            current_fd = next_fd
    except BaseException:
        os.close(current_fd)
        raise
    return current_fd


def _capture_reset_state(
    profile_root: Path,
    candidate: Path,
) -> tuple[int, tuple[int, int], tuple[int, int]]:
    origin_fd = _open_origin_directory(profile_root, candidate.parent.name)
    try:
        idb_fd = os.open("idb", _directory_open_flags(), dir_fd=origin_fd)
        try:
            origin_status = os.fstat(origin_fd)
            idb_status = os.fstat(idb_fd)
            origin_mount_id = _mount_id(origin_fd)
            _validate_mount_tree(idb_fd, origin_mount_id)
            size_bytes = directory_size(Path(f"/proc/self/fd/{idb_fd}"))
        finally:
            os.close(idb_fd)
    finally:
        os.close(origin_fd)
    return (
        size_bytes,
        (origin_status.st_dev, origin_status.st_ino),
        (idb_status.st_dev, idb_status.st_ino),
    )


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
    origin_identity = None
    idb_identity = None
    size_bytes = 0
    if exists:
        try:
            size_bytes, origin_identity, idb_identity = _capture_reset_state(
                profile_root,
                candidate,
            )
        except (OSError, ResetError) as error:
            raise ResetError(f"cannot safely inspect reset path: {candidate}") from error
    return ResetTarget(
        profile=profile,
        path=candidate,
        exists=exists,
        size_bytes=size_bytes,
        origin_identity=origin_identity,
        idb_identity=idb_identity,
    )


# Firefox process preflight and confirmation


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


# Bound target removal and command entry point


def _validate_entry_mount(
    directory_fd: int,
    name: str,
    expected_mount_id: int,
) -> bool:
    try:
        entry_fd = os.open(
            name,
            os.O_PATH | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return False
    try:
        if _mount_id(entry_fd) != expected_mount_id:
            raise ResetError("reset path crosses a mount point")
    finally:
        os.close(entry_fd)
    return True


def _validate_mount_tree(directory_fd: int, expected_mount_id: int) -> None:
    if _mount_id(directory_fd) != expected_mount_id:
        raise ResetError("reset path crosses a mount point")

    with os.scandir(directory_fd) as entries:
        names = tuple(entry.name for entry in entries)
    for name in names:
        try:
            child_fd = os.open(name, _directory_open_flags(), dir_fd=directory_fd)
        except FileNotFoundError:
            continue
        except OSError as error:
            if error.errno not in {errno.ENOTDIR, errno.ELOOP}:
                raise
            _validate_entry_mount(directory_fd, name, expected_mount_id)
            continue
        try:
            _validate_mount_tree(child_fd, expected_mount_id)
        finally:
            os.close(child_fd)


def _verify_target_still_absent(target: ResetTarget) -> None:
    try:
        origin_fd = _open_origin_directory(
            target.profile.path,
            target.path.parent.name,
        )
    except FileNotFoundError:
        return

    try:
        try:
            idb_fd = os.open("idb", _directory_open_flags(), dir_fd=origin_fd)
        except FileNotFoundError:
            return
        else:
            os.close(idb_fd)
            raise ResetError("IndexedDB directory appeared after preview")
    finally:
        os.close(origin_fd)


def prepare_removal_targets(
    targets: Sequence[ResetTarget],
) -> tuple[PreparedResetTarget, ...]:
    grouped_targets: dict[Path, list[ResetTarget]] = {}
    for target in targets:
        grouped_targets.setdefault(target.path, []).append(target)

    prepared: list[PreparedResetTarget] = []
    absent_targets: list[ResetTarget] = []
    try:
        for target_group in grouped_targets.values():
            target = target_group[0]
            report_targets = tuple(target_group)
            if not target.exists:
                _verify_target_still_absent(target)
                absent_targets.append(target)
                prepared.append(
                    PreparedResetTarget(target, report_targets, None, None)
                )
                continue
            origin_fd = _open_origin_directory(
                target.profile.path,
                target.path.parent.name,
            )
            idb_fd = None
            try:
                origin_status = os.fstat(origin_fd)
                idb_fd = os.open("idb", _directory_open_flags(), dir_fd=origin_fd)
                idb_status = os.fstat(idb_fd)
                origin_identity = (origin_status.st_dev, origin_status.st_ino)
                idb_identity = (idb_status.st_dev, idb_status.st_ino)
                if origin_identity != target.origin_identity:
                    raise ResetError("extension origin changed after preview")
                if idb_identity != target.idb_identity:
                    raise ResetError("IndexedDB directory changed after preview")
                origin_mount_id = _mount_id(origin_fd)
                _validate_mount_tree(idb_fd, origin_mount_id)
            except BaseException:
                if idb_fd is not None:
                    os.close(idb_fd)
                os.close(origin_fd)
                raise
            prepared.append(
                PreparedResetTarget(target, report_targets, origin_fd, idb_fd)
            )
        for target in absent_targets:
            _verify_target_still_absent(target)
    except BaseException as error:
        for item in prepared:
            if item.idb_fd is not None:
                os.close(item.idb_fd)
            if item.origin_fd is not None:
                os.close(item.origin_fd)
        if not isinstance(error, (OSError, ResetError)):
            raise
        profile_name = target.profile.name if "target" in locals() else "unknown"
        raise ResetError(f"reset path changed after preview: {profile_name}") from error
    return tuple(prepared)


def _restore_quarantined_idb(
    target: PreparedResetTarget,
    quarantine_name: str,
) -> None:
    assert target.origin_fd is not None
    os.rename(
        quarantine_name,
        "idb",
        src_dir_fd=target.origin_fd,
        dst_dir_fd=target.origin_fd,
    )


def _quarantine_validated_idb(target: PreparedResetTarget) -> str:
    assert target.origin_fd is not None
    assert target.idb_fd is not None
    quarantine_name = f".reset-onepassword-idb-{secrets.token_hex(16)}"
    os.rename(
        "idb",
        quarantine_name,
        src_dir_fd=target.origin_fd,
        dst_dir_fd=target.origin_fd,
    )
    try:
        moved_status = os.stat(
            quarantine_name,
            dir_fd=target.origin_fd,
            follow_symlinks=False,
        )
        verified_status = os.fstat(target.idb_fd)
        moved_identity = (moved_status.st_dev, moved_status.st_ino)
        verified_identity = (verified_status.st_dev, verified_status.st_ino)
        if moved_identity != verified_identity:
            raise ResetError("IndexedDB directory changed before removal")
    except BaseException:
        _restore_quarantined_idb(target, quarantine_name)
        raise
    return quarantine_name


def _clear_directory_fd(directory_fd: int, expected_mount_id: int) -> None:
    if _mount_id(directory_fd) != expected_mount_id:
        raise ResetError("reset path crosses a mount point")

    with os.scandir(directory_fd) as entries:
        names = tuple(entry.name for entry in entries)
    for name in names:
        try:
            child_fd = os.open(name, _directory_open_flags(), dir_fd=directory_fd)
        except FileNotFoundError:
            continue
        except OSError as error:
            if error.errno not in {errno.ENOTDIR, errno.ELOOP}:
                raise
            if _validate_entry_mount(directory_fd, name, expected_mount_id):
                os.unlink(name, dir_fd=directory_fd)
            continue
        try:
            _clear_directory_fd(child_fd, expected_mount_id)
        finally:
            os.close(child_fd)
        os.rmdir(name, dir_fd=directory_fd)


def _report_prepared_target(
    label: str,
    prepared: PreparedResetTarget,
    output: Callable[[str], None],
) -> None:
    for target in prepared.report_targets:
        output(f"{label} {target.profile.name}: {target.path}")


def remove_targets(
    targets: Sequence[PreparedResetTarget], output: Callable[[str], None]
) -> int:
    failed = False
    try:
        for prepared in targets:
            target = prepared.target
            if prepared.origin_fd is None:
                _report_prepared_target("SKIP", prepared, output)
                continue
            try:
                quarantine_name = _quarantine_validated_idb(prepared)
                try:
                    assert prepared.idb_fd is not None
                    expected_mount_id = _mount_id(prepared.origin_fd)
                    _clear_directory_fd(prepared.idb_fd, expected_mount_id)
                    os.rmdir(quarantine_name, dir_fd=prepared.origin_fd)
                except BaseException:
                    _restore_quarantined_idb(prepared, quarantine_name)
                    raise
            except (OSError, ResetError):
                for report_target in prepared.report_targets:
                    output(
                        f"ERROR {report_target.profile.name}: "
                        f"could not remove {report_target.path}"
                    )
                failed = True
            else:
                _report_prepared_target("RESET", prepared, output)
    finally:
        for prepared in targets:
            if prepared.idb_fd is not None:
                os.close(prepared.idb_fd)
            if prepared.origin_fd is not None:
                os.close(prepared.origin_fd)
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

    try:
        active_processes = find_firefox_processes(proc_root)
        if active_processes:
            raise ResetError("Firefox is active; close Firefox before the reset")
        prepared_targets = prepare_removal_targets(targets)
    except ResetError as error:
        output(f"ERROR: {error}")
        return 2

    result = remove_targets(prepared_targets, output)
    if result == 0:
        output("Start Firefox and reconnect 1Password if necessary.")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    return execute(parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
