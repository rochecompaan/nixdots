from __future__ import annotations

import importlib.util
import io
import json
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


def write_uuid_pref(profile: Path, mapping: dict[str, str]) -> Path:
    prefs_js = profile / "prefs.js"
    nested_json = json.dumps(mapping)
    prefs_js.write_text(
        "user_pref(\"extensions.webextensions.uuids\", "
        f"{json.dumps(nested_json)});\n",
        encoding="utf-8",
    )
    return prefs_js


def write_process(proc_root: Path, pid: int, command: str) -> None:
    process = proc_root / str(pid)
    process.mkdir()
    (process / "comm").write_text(f"{command}\n", encoding="utf-8")


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


    def test_directory_size_rejects_unreadable_subtree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "idb"
            path.mkdir()

            def walk_with_error(
                _path,
                *,
                followlinks: bool,
                onerror=None,
            ):
                self.assertFalse(followlinks)
                if onerror is not None:
                    onerror(PermissionError("secret-child-name"))
                return ()

            with mock.patch.object(reset.os, "walk", side_effect=walk_with_error):
                with self.assertRaisesRegex(reset.ResetError, "cannot inspect"):
                    reset.directory_size(path)

    def test_reads_linux_mount_id_from_fdinfo(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)
            fdinfo = proc_root / "self" / "fdinfo"
            fdinfo.mkdir(parents=True)
            (fdinfo / "42").write_text(
                "pos:\t0\nflags:\t0100000\nmnt_id:\t321\n",
                encoding="ascii",
            )
            read_mount_id = getattr(reset, "_mount_id", lambda *_args, **_kwargs: None)

            mount_id = read_mount_id(42, proc_root=proc_root)

        self.assertEqual(mount_id, 321)


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

    def test_firefox_start_during_confirmation_aborts_before_deletion(self) -> None:
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
                idb_files={"data.sqlite": b"keep"},
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )

            def start_firefox() -> str:
                write_process(proc_root, 31, "firefox")
                return "y\n"

            stdin = mock.Mock()
            stdin.isatty.return_value = True
            stdin.readline.side_effect = start_firefox
            output: list[str] = []

            result = reset.execute(
                reset.Options(("default",), False, False),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=stdin,
                output=output.append,
            )

            self.assertTrue(target.is_dir())
        self.assertEqual(result, 2)
        self.assertTrue(any("Firefox is active" in line for line in output))
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

    def test_absent_target_that_appears_aborts_before_any_removal(self) -> None:
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
                idb_files={"data.sqlite": b"keep"},
            )
            _clubhouse_profile, clubhouse_target = create_firefox_profile(
                firefox_root,
                "def.clubhouse",
                self.CLUBHOUSE_UUID,
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
            inspections = 0

            def create_target_after_preview(_proc_root: Path) -> tuple[int, ...]:
                nonlocal inspections
                inspections += 1
                if inspections == 2:
                    clubhouse_target.mkdir(parents=True)
                    (clubhouse_target / "new.sqlite").write_bytes(b"new")
                return ()

            output: list[str] = []
            with mock.patch.object(
                reset,
                "find_firefox_processes",
                side_effect=create_target_after_preview,
            ):
                result = reset.execute(
                    reset.Options((), True, True),
                    firefox_root=firefox_root,
                    proc_root=proc_root,
                    stdin=io.StringIO(),
                    output=output.append,
                )

            self.assertTrue((default_target / "data.sqlite").is_file())
            self.assertTrue((clubhouse_target / "new.sqlite").is_file())
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR:") for line in output))
        self.assertFalse(
            any(line.startswith(("RESET ", "SKIP ")) for line in output)
        )

    def test_repeated_profile_name_resets_target_once(self) -> None:
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
                reset.Options(("default", "default"), False, True),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=io.StringIO(),
                output=output.append,
            )

            self.assertFalse(target.exists())
        self.assertEqual(result, 0)
        self.assertEqual(
            [line for line in output if line.startswith("PLAN ")],
            [f"PLAN default: {target} (4 bytes; present)"],
        )
        self.assertEqual(
            [line for line in output if line.startswith("RESET ")],
            [f"RESET default: {target}"],
        )

    def test_profile_aliases_report_each_name_and_reset_target_once(self) -> None:
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
                "Path=abc.default\n"
                "[Profile1]\n"
                "Name=alias\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )
            output: list[str] = []

            result = reset.execute(
                reset.Options((), True, True),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=io.StringIO(),
                output=output.append,
            )

            self.assertFalse(target.exists())
        self.assertEqual(result, 0)
        self.assertEqual(
            [line for line in output if line.startswith("PLAN ")],
            [
                f"PLAN default: {target} (4 bytes; present)",
                f"PLAN alias: {target} (4 bytes; present)",
            ],
        )
        self.assertEqual(
            [line for line in output if line.startswith("RESET ")],
            [
                f"RESET default: {target}",
                f"RESET alias: {target}",
            ],
        )

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

    def test_absent_target_is_rechecked_after_present_targets_are_prepared(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            absent_profile, absent_path = create_firefox_profile(
                root,
                "abc.default",
                self.DEFAULT_UUID,
            )
            present_profile, present_path = create_firefox_profile(
                root,
                "def.clubhouse",
                self.CLUBHOUSE_UUID,
                idb_files={"data.sqlite": b"keep"},
            )
            targets = (
                reset.build_reset_target(
                    reset.FirefoxProfile("default", absent_profile)
                ),
                reset.build_reset_target(
                    reset.FirefoxProfile("clubhouse", present_profile)
                ),
            )
            original_open = reset._open_origin_directory

            def create_absent_target_while_preparing_present(
                profile_path: Path,
                origin_name: str,
            ) -> int:
                if profile_path == present_profile:
                    absent_path.mkdir(parents=True, exist_ok=True)
                    (absent_path / "new.sqlite").write_bytes(b"new")
                return original_open(profile_path, origin_name)

            with mock.patch.object(
                reset,
                "_open_origin_directory",
                side_effect=create_absent_target_while_preparing_present,
            ):
                with self.assertRaisesRegex(reset.ResetError, "changed after preview"):
                    reset.prepare_removal_targets(targets)

            self.assertTrue((absent_path / "new.sqlite").is_file())
            self.assertTrue((present_path / "data.sqlite").is_file())

    def test_interrupted_preparation_closes_prior_descriptors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first_profile, _first_path = create_firefox_profile(
                root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"data.sqlite": b"first"},
            )
            second_profile, _second_path = create_firefox_profile(
                root,
                "def.clubhouse",
                self.CLUBHOUSE_UUID,
                idb_files={"data.sqlite": b"second"},
            )
            targets = (
                reset.build_reset_target(
                    reset.FirefoxProfile("default", first_profile)
                ),
                reset.build_reset_target(
                    reset.FirefoxProfile("clubhouse", second_profile)
                ),
            )
            original_open = reset._open_origin_directory
            opened_fds: list[int] = []

            def interrupt_second(profile_path: Path, origin_name: str) -> int:
                if opened_fds:
                    raise KeyboardInterrupt
                descriptor = original_open(profile_path, origin_name)
                opened_fds.append(descriptor)
                return descriptor

            with mock.patch.object(
                reset,
                "_open_origin_directory",
                side_effect=interrupt_second,
            ):
                with self.assertRaises(KeyboardInterrupt):
                    reset.prepare_removal_targets(targets)

            with self.assertRaises(OSError):
                reset.os.fstat(opened_fds[0])

    def test_nested_mount_is_rejected_before_any_removal(self) -> None:
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
                idb_files={"data.sqlite": b"keep"},
            )
            _clubhouse_profile, clubhouse_target = create_firefox_profile(
                firefox_root,
                "def.clubhouse",
                self.CLUBHOUSE_UUID,
                idb_files={"mounted/external.sqlite": b"external"},
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

            def simulated_mount_id(directory_fd: int) -> int:
                path = Path(reset.os.readlink(f"/proc/self/fd/{directory_fd}"))
                return 2 if path.name == "mounted" else 1

            output: list[str] = []
            with mock.patch.object(
                reset,
                "_mount_id",
                create=True,
                side_effect=simulated_mount_id,
            ):
                result = reset.execute(
                    reset.Options((), True, True),
                    firefox_root=firefox_root,
                    proc_root=proc_root,
                    stdin=io.StringIO(),
                    output=output.append,
                )

            self.assertTrue((default_target / "data.sqlite").is_file())
            self.assertTrue(
                (clubhouse_target / "mounted" / "external.sqlite").is_file()
            )
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR:") for line in output))
        self.assertFalse(any(line.startswith("RESET ") for line in output))

    def test_file_mount_is_rejected_before_any_removal(self) -> None:
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
                idb_files={
                    "ordinary.sqlite": b"keep",
                    "mounted.sqlite": b"external",
                },
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )

            def simulated_mount_id(entry_fd: int) -> int:
                path = Path(reset.os.readlink(f"/proc/self/fd/{entry_fd}"))
                return 2 if path.name == "mounted.sqlite" else 1

            output: list[str] = []
            with mock.patch.object(
                reset,
                "_mount_id",
                side_effect=simulated_mount_id,
            ):
                result = reset.execute(
                    reset.Options(("default",), False, True),
                    firefox_root=firefox_root,
                    proc_root=proc_root,
                    stdin=io.StringIO(),
                    output=output.append,
                )

            self.assertTrue((target / "ordinary.sqlite").is_file())
            self.assertTrue((target / "mounted.sqlite").is_file())
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR:") for line in output))
        self.assertFalse(any(line.startswith("RESET ") for line in output))

    def test_mount_that_appears_after_preparation_is_not_traversed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, target_path = create_firefox_profile(
                root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"mounted/external.sqlite": b"external"},
            )
            target = reset.build_reset_target(
                reset.FirefoxProfile("default", profile)
            )
            nested_mount_checks = 0

            def changing_mount_id(directory_fd: int) -> int:
                nonlocal nested_mount_checks
                path = Path(reset.os.readlink(f"/proc/self/fd/{directory_fd}"))
                if path.name != "mounted":
                    return 1
                nested_mount_checks += 1
                return 1 if nested_mount_checks == 1 else 2

            output: list[str] = []
            with mock.patch.object(
                reset,
                "_mount_id",
                create=True,
                side_effect=changing_mount_id,
            ):
                prepared = reset.prepare_removal_targets((target,))
                result = reset.remove_targets(prepared, output.append)

            self.assertTrue(
                (target_path / "mounted" / "external.sqlite").is_file()
            )
            self.assertFalse(
                any(
                    path.name.startswith(".reset-onepassword-idb-")
                    for path in target_path.parent.iterdir()
                )
            )
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR default:") for line in output))
        self.assertFalse(any(line.startswith("RESET ") for line in output))

    def test_file_mount_that_appears_after_preparation_is_not_unlinked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, target_path = create_firefox_profile(
                root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"mounted.sqlite": b"external"},
            )
            target = reset.build_reset_target(
                reset.FirefoxProfile("default", profile)
            )
            file_mount_checks = 0

            def changing_mount_id(entry_fd: int) -> int:
                nonlocal file_mount_checks
                path = Path(reset.os.readlink(f"/proc/self/fd/{entry_fd}"))
                if path.name != "mounted.sqlite":
                    return 1
                file_mount_checks += 1
                return 1 if file_mount_checks == 1 else 2

            output: list[str] = []
            with mock.patch.object(
                reset,
                "_mount_id",
                side_effect=changing_mount_id,
            ):
                prepared = reset.prepare_removal_targets((target,))
                result = reset.remove_targets(prepared, output.append)

            self.assertTrue((target_path / "mounted.sqlite").is_file())
            self.assertFalse(
                any(
                    path.name.startswith(".reset-onepassword-idb-")
                    for path in target_path.parent.iterdir()
                )
            )
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR default:") for line in output))
        self.assertFalse(any(line.startswith("RESET ") for line in output))

    def test_idb_swap_after_preparation_preserves_replacement_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, target_path = create_firefox_profile(
                root,
                "abc.default",
                self.DEFAULT_UUID,
                idb_files={"selected.sqlite": b"selected"},
            )
            target = reset.build_reset_target(
                reset.FirefoxProfile("default", profile)
            )
            prepared = reset.prepare_removal_targets((target,))
            saved_target = target_path.parent / "saved-idb"
            target_path.rename(saved_target)
            target_path.mkdir()
            replacement_file = target_path / "replacement.sqlite"
            replacement_file.write_bytes(b"replacement")
            output: list[str] = []

            result = reset.remove_targets(prepared, output.append)

            self.assertTrue((saved_target / "selected.sqlite").is_file())
            self.assertTrue(replacement_file.is_file())
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR default:") for line in output))
        self.assertFalse(any(line.startswith("RESET ") for line in output))

    def test_post_rename_error_restores_the_indexeddb_directory(self) -> None:
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
                idb_files={"data.sqlite": b"keep"},
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )
            real_stat = reset.os.stat

            def fail_quarantine_stat(path, *args, **kwargs):
                if isinstance(path, str) and path.startswith(
                    ".reset-onepassword-idb-"
                ):
                    raise PermissionError("injected post-rename failure")
                return real_stat(path, *args, **kwargs)

            output: list[str] = []
            with mock.patch.object(
                reset.os,
                "stat",
                side_effect=fail_quarantine_stat,
            ):
                result = reset.execute(
                    reset.Options(("default",), False, True),
                    firefox_root=firefox_root,
                    proc_root=proc_root,
                    stdin=io.StringIO(),
                    output=output.append,
                )

            self.assertTrue((target / "data.sqlite").is_file())
            self.assertFalse(
                any(
                    path.name.startswith(".reset-onepassword-idb-")
                    for path in target.parent.iterdir()
                )
            )
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR default:") for line in output))
        self.assertFalse(any(line.startswith("RESET ") for line in output))

    def test_interruption_after_rename_restores_the_indexeddb_directory(self) -> None:
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
                idb_files={"data.sqlite": b"keep"},
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )

            with mock.patch.object(
                reset,
                "_clear_directory_fd",
                side_effect=KeyboardInterrupt,
            ):
                with self.assertRaises(KeyboardInterrupt):
                    reset.execute(
                        reset.Options(("default",), False, True),
                        firefox_root=firefox_root,
                        proc_root=proc_root,
                        stdin=io.StringIO(),
                        output=lambda _line: None,
                    )

            self.assertTrue((target / "data.sqlite").is_file())
            self.assertFalse(
                any(
                    path.name.startswith(".reset-onepassword-idb-")
                    for path in target.parent.iterdir()
                )
            )

    def test_parent_symlink_swap_during_confirmation_preserves_external_data(
        self,
    ) -> None:
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
                idb_files={"selected.sqlite": b"selected"},
            )
            write_profiles_ini(
                firefox_root,
                "[Profile0]\n"
                "Name=default\n"
                "IsRelative=1\n"
                "Path=abc.default\n",
            )
            origin = target.parent
            saved_origin = root / "saved-origin"
            outside_origin = root / "outside-origin"
            outside_target = outside_origin / "idb"
            outside_target.mkdir(parents=True)
            outside_file = outside_target / "outside.sqlite"
            outside_file.write_bytes(b"outside")

            def swap_origin() -> str:
                origin.rename(saved_origin)
                origin.symlink_to(outside_origin, target_is_directory=True)
                return "y\n"

            stdin = mock.Mock()
            stdin.isatty.return_value = True
            stdin.readline.side_effect = swap_origin
            output: list[str] = []

            result = reset.execute(
                reset.Options(("default",), False, False),
                firefox_root=firefox_root,
                proc_root=proc_root,
                stdin=stdin,
                output=output.append,
            )

            self.assertTrue((saved_origin / "idb" / "selected.sqlite").is_file())
            self.assertTrue(outside_file.is_file())
        self.assertEqual(result, 2)
        self.assertTrue(any(line.startswith("ERROR") for line in output))
        self.assertFalse(any(line.startswith("RESET ") for line in output))

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
                reset.os,
                "unlink",
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


if __name__ == "__main__":
    unittest.main()
