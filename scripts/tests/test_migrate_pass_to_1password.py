from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "migrate-pass-to-1password.py"
SPEC = importlib.util.spec_from_file_location("migrate_pass_to_1password", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
migration = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = migration
SPEC.loader.exec_module(migration)


class EntryParsingTests(unittest.TestCase):
    def test_parse_login_metadata_totp_custom_fields_and_notes(self) -> None:
        entry = migration.parse_pass_output(
            "private/github",
            "correct horse battery staple\n"
            "username: Alice@example.com\n"
            "email: second@example.com\n"
            "url: https://Example.com/login#fragment\n"
            "otp: otpauth://totp/GitHub:alice?secret=TESTFIXTURE\n"
            "backup code: SYNTHETIC-CODE\n"
            "free-form note\n",
        )

        self.assertEqual(entry.path, "private/github")
        self.assertEqual(entry.title, "github")
        self.assertEqual(entry.secret, "correct horse battery staple")
        self.assertEqual(entry.usernames, ("Alice@example.com", "second@example.com"))
        self.assertEqual(entry.urls, ("https://Example.com/login#fragment",))
        self.assertEqual(entry.totp, ("otpauth://totp/GitHub:alice?secret=TESTFIXTURE",))
        self.assertEqual(entry.custom_fields[0].label, "backup code")
        self.assertTrue(entry.custom_fields[0].concealed)
        self.assertEqual(entry.notes, "free-form note")

    def test_rejects_missing_primary_secret(self) -> None:
        with self.assertRaisesRegex(migration.EntryParseError, "primary secret"):
            migration.parse_pass_output("private/empty", "")

    def test_classifies_api_marker_before_login_fields(self) -> None:
        entry = migration.parse_pass_output(
            "services/openrouter-api-key",
            "synthetic-api-value\nusername: automation\nurl: https://openrouter.ai/\n",
        )
        self.assertEqual(migration.classify_entry(entry), migration.Category.API_CREDENTIAL)

    def test_classifies_login_and_password_fallback(self) -> None:
        login = migration.parse_pass_output(
            "private/example", "synthetic-password\nurl: https://example.com\n"
        )
        password = migration.parse_pass_output("private/door-code", "123456\n")
        self.assertEqual(migration.classify_entry(login), migration.Category.LOGIN)
        self.assertEqual(migration.classify_entry(password), migration.Category.PASSWORD)

    def test_normalizers_follow_matching_contract(self) -> None:
        self.assertEqual(migration.normalize_title("  GitHub   Admin  "), "github admin")
        self.assertEqual(migration.normalize_label("Client_Secret"), "client secret")
        self.assertEqual(migration.normalize_username("  ALICE@example.com "), "alice@example.com")


class DiscoveryAndCommandTests(unittest.TestCase):
    def test_discovers_deduplicated_current_gpg_additions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory)
            (store / "private").mkdir()
            (store / "private" / "new.gpg").write_bytes(b"synthetic encrypted bytes")
            calls: list[tuple[list[str], dict[str, object]]] = []

            def fake_runner(args, **kwargs):
                calls.append((list(args), kwargs))
                return "private/new.gpg\0private/new.gpg\0private/deleted.gpg\0"

            found = migration.discover_entries(store, "2026-01-01", runner=fake_runner)

        self.assertEqual(found, ["private/new"])
        self.assertEqual(
            calls[0][0],
            [
                "git",
                "-C",
                str(store),
                "log",
                "--since=2026-01-01",
                "--diff-filter=A",
                "--name-only",
                "--format=",
                "-z",
                "--",
                "*.gpg",
            ],
        )

    def test_real_git_history_selects_recent_additions_not_modifications(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory)
            subprocess.run(
                ["git", "init", "--quiet", str(store)],
                check=True,
                capture_output=True,
                text=True,
            )
            old = int(datetime(2025, 1, 1, tzinfo=timezone.utc).timestamp())
            recent = int(datetime(2026, 2, 1, tzinfo=timezone.utc).timestamp())
            deleted = int(datetime(2026, 2, 2, tzinfo=timezone.utc).timestamp())
            stream = (
                "commit refs/heads/main\n"
                "mark :1\n"
                f"author Test <test@example.com> {old} +0000\n"
                f"committer Test <test@example.com> {old} +0000\n"
                "data 7\ninitial\n"
                "M 100644 inline old.gpg\n"
                "data 4\nold\n"
                "\n"
                "commit refs/heads/main\n"
                "mark :2\n"
                f"author Test <test@example.com> {recent} +0000\n"
                f"committer Test <test@example.com> {recent} +0000\n"
                "data 6\nrecent\n"
                "from :1\n"
                "M 100644 inline old.gpg\n"
                "data 8\nchanged\n"
                "M 100644 inline private/new.gpg\n"
                "data 4\nnew\n"
                "M 100644 inline private/deleted.gpg\n"
                "data 5\ngone\n"
                "\n"
                "commit refs/heads/main\n"
                "mark :3\n"
                f"author Test <test@example.com> {deleted} +0000\n"
                f"committer Test <test@example.com> {deleted} +0000\n"
                "data 6\ndelete\n"
                "from :2\n"
                "D private/deleted.gpg\n"
                "\n"
            )
            subprocess.run(
                ["git", "fast-import", "--quiet"],
                cwd=store,
                input=stream,
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["git", "reset", "--hard", "main"],
                cwd=store,
                check=True,
                capture_output=True,
                text=True,
            )

            found = migration.discover_entries(store, "2026-01-01")

        self.assertEqual(found, ["private/new"])

    def test_decrypt_entry_sets_only_the_store_path_in_environment(self) -> None:
        calls: list[tuple[list[str], dict[str, object]]] = []

        def fake_runner(args, **kwargs):
            calls.append((list(args), kwargs))
            return "synthetic-secret\nusername: alice\n"

        output = migration.decrypt_entry(
            Path("/tmp/synthetic-store"), "private/example", runner=fake_runner
        )

        self.assertEqual(output.splitlines()[0], "synthetic-secret")
        self.assertEqual(calls[0][0], ["pass", "show", "--", "private/example"])
        self.assertEqual(
            calls[0][1]["env_updates"],
            {"PASSWORD_STORE_DIR": "/tmp/synthetic-store"},
        )
        self.assertNotIn("synthetic-secret", repr(calls))

    def test_command_error_never_includes_stderr(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["pass", "show"], returncode=1, stdout="", stderr="SENSITIVE"
        )
        with mock.patch.object(migration.subprocess, "run", return_value=completed):
            with self.assertRaises(migration.CommandError) as caught:
                migration.run_command(["pass", "show", "--", "entry"])

        self.assertEqual(str(caught.exception), "pass command failed with exit status 1")
        self.assertNotIn("SENSITIVE", str(caught.exception))


class OnePasswordMappingTests(unittest.TestCase):
    def login_template(self) -> dict[str, object]:
        return {
            "title": "",
            "category": "LOGIN",
            "fields": [
                {
                    "id": "notesPlain",
                    "type": "STRING",
                    "purpose": "NOTES",
                    "label": "notesPlain",
                    "value": "",
                },
                {
                    "id": "username",
                    "type": "STRING",
                    "purpose": "USERNAME",
                    "label": "username",
                    "value": "",
                },
                {
                    "id": "password",
                    "type": "CONCEALED",
                    "purpose": "PASSWORD",
                    "label": "password",
                    "value": "",
                },
            ],
        }

    def test_builds_login_payload_with_totp_path_tag_and_metadata(self) -> None:
        entry = migration.parse_pass_output(
            "private/github",
            "synthetic-password\n"
            "username: Alice@example.com\n"
            "email: backup@example.com\n"
            "url: https://Example.com/login#fragment\n"
            "otp: otpauth://totp/GitHub:alice?secret=TESTFIXTURE\n"
            "client secret: EXTRA-SYNTHETIC\n"
            "migration note\n",
        )
        payload = migration.build_item_payload(
            entry, migration.Category.LOGIN, self.login_template()
        )
        fields = {field["id"]: field for field in payload["fields"]}

        self.assertEqual(payload["title"], "github")
        self.assertEqual(payload["tags"], ["migrated-from-pass"])
        self.assertEqual(fields["username"]["value"], "Alice@example.com")
        self.assertEqual(fields["password"]["value"], "synthetic-password")
        self.assertEqual(fields["notesPlain"]["value"], "migration note")
        self.assertEqual(
            payload["urls"][0]["href"], "https://Example.com/login#fragment"
        )
        custom = {field["label"]: field for field in payload["fields"]}
        self.assertEqual(custom["pass path"]["value"], "private/github")
        self.assertEqual(custom["one-time password"]["type"], "OTP")
        self.assertEqual(custom["client secret"]["type"], "CONCEALED")
        self.assertEqual(custom["email 2"]["value"], "backup@example.com")

    def test_builds_api_credential_and_password_payloads(self) -> None:
        api_template = {
            "title": "",
            "category": "API_CREDENTIAL",
            "fields": [
                {
                    "id": "notesPlain",
                    "type": "STRING",
                    "purpose": "NOTES",
                    "label": "notesPlain",
                    "value": "",
                },
                {
                    "id": "username",
                    "type": "STRING",
                    "label": "username",
                    "value": "",
                },
                {
                    "id": "credential",
                    "type": "CONCEALED",
                    "label": "credential",
                    "value": "",
                },
                {
                    "id": "hostname",
                    "type": "STRING",
                    "label": "hostname",
                    "value": "",
                },
            ],
        }
        password_template = {
            "title": "",
            "category": "PASSWORD",
            "fields": [
                {
                    "id": "notesPlain",
                    "type": "STRING",
                    "purpose": "NOTES",
                    "label": "notesPlain",
                    "value": "",
                },
                {
                    "id": "password",
                    "type": "CONCEALED",
                    "purpose": "PASSWORD",
                    "label": "password",
                    "value": "",
                },
            ],
        }
        api_entry = migration.parse_pass_output(
            "api/service-token",
            "SYNTHETIC-API\nusername: automation\nurl: https://api.example.com/v1\n",
        )
        password_entry = migration.parse_pass_output("private/pin", "123456\n")

        api_payload = migration.build_item_payload(
            api_entry, migration.Category.API_CREDENTIAL, api_template
        )
        password_payload = migration.build_item_payload(
            password_entry, migration.Category.PASSWORD, password_template
        )
        api_fields = {field["id"]: field for field in api_payload["fields"]}
        password_fields = {
            field["id"]: field for field in password_payload["fields"]
        }

        self.assertEqual(api_fields["credential"]["value"], "SYNTHETIC-API")
        self.assertEqual(api_fields["hostname"]["value"], "api.example.com")
        self.assertEqual(password_fields["password"]["value"], "123456")
        self.assertTrue(
            any(field["label"] == "pass path" for field in password_payload["fields"])
        )

    def test_canonicalizes_urls_without_reducing_them_to_hosts(self) -> None:
        self.assertEqual(
            migration.canonicalize_url("HTTPS://Example.COM:443/login#fragment"),
            "https://example.com/login",
        )
        self.assertNotEqual(
            migration.canonicalize_url("https://example.com/login"),
            migration.canonicalize_url("https://example.com/admin"),
        )

    def test_matching_prefers_path_then_identifiers_and_reports_ambiguity(self) -> None:
        entry = migration.parse_pass_output(
            "private/github",
            "synthetic-password\nusername: Alice@example.com\n"
            "url: https://example.com/login\n",
        )
        by_path = migration.ExistingItem(
            "item-path", "GITHUB", (), (), ("private/github",)
        )
        by_username = migration.ExistingItem(
            "item-user", "GITHUB", ("alice@example.com",), (), ()
        )
        different = migration.ExistingItem(
            "item-other",
            "github",
            ("bob@example.com",),
            ("https://example.com/admin",),
            (),
        )

        self.assertEqual(
            migration.match_existing(entry, [by_path, by_username]).item_ids,
            ("item-path",),
        )
        self.assertEqual(
            migration.match_existing(entry, [by_username]).kind,
            migration.MatchKind.MATCH,
        )
        self.assertEqual(
            migration.match_existing(entry, [different]).kind,
            migration.MatchKind.NONE,
        )
        second_username = migration.ExistingItem(
            "item-user-2", "github", ("alice@example.com",), (), ()
        )
        ambiguous = migration.match_existing(entry, [by_username, second_username])
        self.assertEqual(ambiguous.kind, migration.MatchKind.AMBIGUOUS)
        self.assertEqual(ambiguous.item_ids, ("item-user", "item-user-2"))

        title_only_entry = migration.parse_pass_output("private/pin", "123456\n")
        title_only_item = migration.ExistingItem("item-pin", "PIN", (), (), ())
        self.assertEqual(
            migration.match_existing(title_only_entry, [title_only_item]).kind,
            migration.MatchKind.MATCH,
        )

    def test_existing_secondary_username_participates_in_matching(self) -> None:
        source = migration.parse_pass_output(
            "private/github",
            "synthetic-password\nusername: backup@example.com\n",
        )
        existing = migration.existing_item_from_json(
            {
                "id": "existing-id",
                "title": "github",
                "fields": [
                    {
                        "id": "passMigration004",
                        "type": "STRING",
                        "label": "email 2",
                        "value": "backup@example.com",
                    }
                ],
            }
        )

        self.assertEqual(existing.usernames, ("backup@example.com",))
        self.assertEqual(
            migration.match_existing(source, [existing]).kind,
            migration.MatchKind.MATCH,
        )

    def test_existing_numbered_url_participates_in_matching(self) -> None:
        source = migration.parse_pass_output(
            "api/service-token",
            "synthetic-token\nurl: https://api.example.com/v1\n",
        )
        existing = migration.existing_item_from_json(
            {
                "id": "existing-id",
                "title": "service-token",
                "fields": [
                    {
                        "id": "passMigration004",
                        "type": "STRING",
                        "label": "url 1",
                        "value": "https://api.example.com/v1",
                    }
                ],
            }
        )

        self.assertEqual(existing.urls, ("https://api.example.com/v1",))
        self.assertEqual(
            migration.match_existing(source, [existing]).kind,
            migration.MatchKind.MATCH,
        )

    def test_existing_item_parser_never_reads_concealed_values(self) -> None:
        class ConcealedField(dict):
            def get(self, key, default=None):
                if key == "value":
                    raise AssertionError("concealed value was read")
                return super().get(key, default)

        existing = migration.existing_item_from_json(
            {
                "id": "existing-id",
                "title": "github",
                "fields": [
                    ConcealedField(
                        {
                            "id": "password",
                            "type": "CONCEALED",
                            "purpose": "PASSWORD",
                            "label": "password",
                        }
                    )
                ],
            }
        )

        self.assertEqual(existing.usernames, ())
        self.assertEqual(existing.urls, ())
        self.assertEqual(existing.pass_paths, ())

    def test_rejects_malformed_op_response_shapes(self) -> None:
        cases = {
            "item list object": lambda: migration.list_item_summaries(
                "Private", runner=lambda args, **kwargs: "{}"
            ),
            "template list": lambda: migration.load_templates(
                runner=lambda args, **kwargs: "[]"
            ),
            "item detail list": lambda: migration.get_existing_item(
                "item-id", "Private", runner=lambda args, **kwargs: "[]"
            ),
            "create result list": lambda: migration.create_item(
                {"title": "synthetic"},
                "Private",
                runner=lambda args, **kwargs: "[]",
            ),
        }

        for label, operation in cases.items():
            with self.subTest(label=label):
                with self.assertRaises(migration.MigrationError):
                    operation()

    def test_create_item_sends_secret_only_on_stdin(self) -> None:
        calls: list[tuple[list[str], dict[str, object]]] = []

        def fake_runner(args, **kwargs):
            calls.append((list(args), kwargs))
            return '{"id":"created-id","title":"example","category":"LOGIN"}'

        payload = {
            "title": "example",
            "category": "LOGIN",
            "secret": "SYNTHETIC",
        }
        created = migration.create_item(payload, "Private", runner=fake_runner)

        self.assertEqual(created["id"], "created-id")
        self.assertNotIn("SYNTHETIC", repr(calls[0][0]))
        self.assertNotIn("SYNTHETIC", repr(calls[0][1].get("env_updates")))
        self.assertEqual(json.loads(calls[0][1]["input_text"]), payload)


class OrchestrationTests(unittest.TestCase):
    def template(self, category: str) -> dict[str, object]:
        fields = [
            {
                "id": "notesPlain",
                "type": "STRING",
                "purpose": "NOTES",
                "label": "notesPlain",
                "value": "",
            }
        ]
        if category in {"LOGIN", "API_CREDENTIAL"}:
            fields.append(
                {
                    "id": "username",
                    "type": "STRING",
                    "label": "username",
                    "value": "",
                }
            )
        if category == "API_CREDENTIAL":
            fields.extend(
                [
                    {
                        "id": "credential",
                        "type": "CONCEALED",
                        "label": "credential",
                        "value": "",
                    },
                    {
                        "id": "hostname",
                        "type": "STRING",
                        "label": "hostname",
                        "value": "",
                    },
                ]
            )
        else:
            fields.append(
                {
                    "id": "password",
                    "type": "CONCEALED",
                    "label": "password",
                    "value": "",
                }
            )
        return {"title": "", "category": category, "fields": fields}

    def test_dry_run_plans_without_calling_create_or_printing_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory)
            (store / "private").mkdir()
            (store / "private" / "github.gpg").write_bytes(b"encrypted")
            calls: list[list[str]] = []

            def fake_runner(args, **kwargs):
                command = list(args)
                calls.append(command)
                if (
                    command[0:3] == ["git", "-C", str(store)]
                    and "rev-parse" in command
                ):
                    return "true\n"
                if command[:3] == ["op", "vault", "get"]:
                    return "{}"
                if command[:4] == ["op", "item", "template", "get"]:
                    name = command[4]
                    schema = {
                        "Login": "LOGIN",
                        "API Credential": "API_CREDENTIAL",
                        "Password": "PASSWORD",
                    }[name]
                    return json.dumps(self.template(schema))
                if command[:3] == ["op", "item", "list"]:
                    return "[]"
                if command[0] == "git" and "log" in command:
                    return "private/github.gpg\0"
                if command[:2] == ["pass", "show"]:
                    return (
                        "SYNTHETIC-PASSWORD\nusername: alice\n"
                        "url: https://example.com\n"
                    )
                if command[:3] == ["op", "item", "create"]:
                    self.fail("dry run invoked item creation")
                raise AssertionError(command)

            output: list[str] = []
            options = migration.Options(store, "Private", "6 months ago", False)
            result = migration.execute(
                options,
                runner=fake_runner,
                which=lambda name: f"/fake/{name}",
                output=output.append,
            )

        self.assertEqual(result, 0)
        self.assertTrue(
            any(line.startswith("CREATE private/github [Login]") for line in output)
        )
        self.assertNotIn("SYNTHETIC-PASSWORD", "\n".join(output))
        self.assertFalse(
            any(command[:3] == ["op", "item", "create"] for command in calls)
        )

    def test_preflight_failure_returns_two_without_decrypting(self) -> None:
        output: list[str] = []
        options = migration.Options(
            Path("/missing/store"), "Private", "6 months ago", False
        )
        result = migration.execute(
            options,
            runner=lambda args, **kwargs: self.fail("runner should not be called"),
            which=lambda name: None,
            output=output.append,
        )
        self.assertEqual(result, 2)
        self.assertTrue(output[0].startswith("ERROR preflight:"))

    def test_malformed_op_response_is_a_sanitized_preflight_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory)

            def fake_runner(args, **kwargs):
                command = list(args)
                if command[0] == "git" and "rev-parse" in command:
                    return "true\n"
                if command[:3] == ["op", "vault", "get"]:
                    return "{}"
                if command[:4] == ["op", "item", "template", "get"]:
                    return "[]"
                raise AssertionError(command)

            output: list[str] = []
            result = migration.execute(
                migration.Options(store, "Private", "6 months ago", False),
                runner=fake_runner,
                which=lambda name: f"/fake/{name}",
                output=output.append,
            )

        self.assertEqual(result, 2)
        self.assertEqual(
            output,
            ["ERROR preflight: op returned invalid Login template response"],
        )

    def test_ambiguity_returns_one_and_continues_to_later_entries(self) -> None:
        options = migration.Options(
            Path("/synthetic/store"), "Private", "6 months ago", False
        )
        summaries = {
            "example": [
                migration.ItemSummary("item-a", "example", "LOGIN"),
                migration.ItemSummary("item-b", "example", "LOGIN"),
            ]
        }
        context = migration.MigrationContext({}, summaries, {})
        existing = {
            item_id: migration.ExistingItem(
                item_id, "example", ("alice@example.com",), (), ()
            )
            for item_id in ("item-a", "item-b")
        }

        def decrypted(_store, entry_path, **_kwargs):
            if entry_path == "private/example":
                return "SYNTHETIC\nusername: alice@example.com\n"
            return "654321\n"

        output: list[str] = []
        with mock.patch.object(
            migration, "preflight", return_value=context
        ), mock.patch.object(
            migration,
            "discover_entries",
            return_value=["private/example", "private/other"],
        ), mock.patch.object(
            migration, "decrypt_entry", side_effect=decrypted
        ), mock.patch.object(
            migration,
            "get_existing_item",
            side_effect=lambda item_id, *_args, **_kwargs: existing[item_id],
        ):
            result = migration.execute(options, output=output.append)

        self.assertEqual(result, 1)
        self.assertTrue(
            any(line.startswith("AMBIGUOUS private/example") for line in output)
        )
        self.assertTrue(any(line.startswith("CREATE private/other") for line in output))


FAKE_CLI = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = Path(os.environ["FAKE_OP_STATE"])
state = json.loads(state_path.read_text())


def template(category):
    fields = [
        {"id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain", "value": ""}
    ]
    if category in {"LOGIN", "API_CREDENTIAL"}:
        fields.append({"id": "username", "type": "STRING", "label": "username", "value": ""})
    if category == "API_CREDENTIAL":
        fields.extend([
            {"id": "credential", "type": "CONCEALED", "label": "credential", "value": ""},
            {"id": "hostname", "type": "STRING", "label": "hostname", "value": ""},
        ])
    else:
        fields.append({"id": "password", "type": "CONCEALED", "label": "password", "value": ""})
    return {"title": "", "category": category, "fields": fields}


if name == "git":
    if "rev-parse" in args:
        print("true")
    elif "log" in args:
        sys.stdout.write("private/github.gpg\0api/service-token.gpg\0")
    else:
        raise SystemExit(3)
elif name == "pass":
    values = {
        "private/github": (
            "SYNTHETIC-LOGIN-SECRET\n"
            "username: alice@example.com\n"
            "url: https://example.com/login\n"
            "otp: otpauth://totp/Example:alice?secret=TESTFIXTURE\n"
        ),
        "api/service-token": "SYNTHETIC-API-SECRET\n",
    }
    sys.stdout.write(values[args[-1]])
elif name == "op":
    if args[:2] == ["vault", "get"]:
        print("{}")
    elif args[:3] == ["item", "template", "get"]:
        category = {
            "Login": "LOGIN",
            "API Credential": "API_CREDENTIAL",
            "Password": "PASSWORD",
        }[args[3]]
        print(json.dumps(template(category)))
    elif args[:2] == ["item", "list"]:
        print(json.dumps([
            {"id": item["id"], "title": item["title"], "category": item["category"]}
            for item in state["items"]
        ]))
    elif args[:2] == ["item", "get"]:
        item_id = args[2]
        print(json.dumps(next(item for item in state["items"] if item["id"] == item_id)))
    elif args[:2] == ["item", "create"]:
        payload = json.load(sys.stdin)
        payload["id"] = f"created-{len(state['items']) + 1}"
        state["items"].append(payload)
        state_path.write_text(json.dumps(state))
        print(json.dumps(payload))
    else:
        raise SystemExit(4)
else:
    raise SystemExit(5)
'''


class EndToEndTests(unittest.TestCase):
    def test_dry_run_apply_and_rerun_are_safe_and_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            store = root / "store"
            fake_bin.mkdir()
            (store / "private").mkdir(parents=True)
            (store / "api").mkdir()
            (store / "private" / "github.gpg").write_bytes(b"encrypted")
            (store / "api" / "service-token.gpg").write_bytes(b"encrypted")

            dispatcher = fake_bin / "dispatcher"
            dispatcher.write_text(FAKE_CLI)
            dispatcher.chmod(0o700)
            for command in ("git", "pass", "op"):
                (fake_bin / command).symlink_to(dispatcher)

            state_path = root / "state.json"
            state_path.write_text(
                json.dumps(
                    {
                        "items": [
                            {
                                "id": "existing-api",
                                "title": "service-token",
                                "category": "API_CREDENTIAL",
                                "fields": [
                                    {
                                        "id": "passMigration001",
                                        "type": "STRING",
                                        "label": "pass path",
                                        "value": "api/service-token",
                                    }
                                ],
                            }
                        ]
                    }
                )
            )
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            environment["FAKE_OP_STATE"] = str(state_path)

            dry_run = subprocess.run(
                [str(SCRIPT), "--store", str(store)],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
            self.assertIn("CREATE private/github [Login]", dry_run.stdout)
            self.assertIn(
                "SKIP api/service-token [API Credential]", dry_run.stdout
            )
            self.assertNotIn("SYNTHETIC-LOGIN-SECRET", dry_run.stdout)
            self.assertEqual(len(json.loads(state_path.read_text())["items"]), 1)

            apply = subprocess.run(
                [str(SCRIPT), "--store", str(store), "--apply"],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            self.assertEqual(apply.returncode, 0, apply.stderr)
            self.assertIn("CREATED private/github [Login]", apply.stdout)
            state = json.loads(state_path.read_text())
            self.assertEqual(len(state["items"]), 2)
            created = next(
                item for item in state["items"] if item["id"].startswith("created-")
            )
            fields = {field["label"]: field for field in created["fields"]}
            self.assertEqual(fields["pass path"]["value"], "private/github")
            self.assertEqual(fields["one-time password"]["type"], "OTP")
            self.assertEqual(created["tags"], ["migrated-from-pass"])

            rerun = subprocess.run(
                [str(SCRIPT), "--store", str(store), "--apply"],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            self.assertEqual(rerun.returncode, 0, rerun.stderr)
            self.assertNotIn("CREATED", rerun.stdout)
            self.assertEqual(len(json.loads(state_path.read_text())["items"]), 2)


if __name__ == "__main__":
    unittest.main()
