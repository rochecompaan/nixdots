import json
import os
import stat
import subprocess

from metadata_index import (
    build_grep_stdout,
    default_index_path,
    extract_metadata_fields,
    load_index,
    refresh_index,
    run_metadata_request,
    write_index,
)


def test_extract_metadata_fields_skips_password_line_and_filters_fields():
    content = "url: not-a-password-field\nurl: example.com\nhttps: https://secure.example.com\nlogin: user@example.com\n"

    fields = extract_metadata_fields(content, ["url", "https"])

    assert fields == {
        "url": ["example.com"],
        "https": ["https://secure.example.com"],
    }


def test_build_grep_stdout_matches_pass_grep_shape():
    index = {
        "version": 1,
        "entries": [
            {
                "path": "private/login/example.com-user",
                "fields": {
                    "url": ["https://example.com"],
                    "http": ["internal.example.test"],
                },
                "mtime": 123,
            },
            {
                "path": "private/login/no-url",
                "fields": {"login": ["user"]},
                "mtime": 456,
            },
        ],
    }

    assert build_grep_stdout(index, ["url", "http"]) == (
        "private/login/example.com-user:\n"
        "url: https://example.com\n"
        "http: internal.example.test\n"
    )


def test_run_metadata_request_returns_empty_success_when_index_missing(tmp_path):
    response = run_metadata_request(["grepMetaUrls", ["url", "http"]], index_path=tmp_path / "missing.json")

    assert response == {"exitCode": 0, "stdout": "", "stderr": "", "version": "1.2.5"}


def test_write_index_uses_private_file_mode(tmp_path):
    index_path = tmp_path / "metadata-index.json"

    write_index(index_path, {"version": 1, "entries": []})

    assert load_index(index_path) == {"version": 1, "entries": []}
    assert stat.S_IMODE(index_path.stat().st_mode) == 0o600


def test_refresh_index_decrypts_entries_one_at_a_time_and_indexes_url_fields(tmp_path):
    store = tmp_path / "store"
    (store / "private" / "login").mkdir(parents=True)
    (store / "private" / "login" / "example.gpg").write_text("encrypted", encoding="utf-8")
    (store / "ignored.txt").write_text("ignored", encoding="utf-8")
    index_path = tmp_path / "index.json"
    calls = []

    def fake_runner(command, **kwargs):
        calls.append(command)
        assert command[:3] == ["/bin/pass", "show", "--"]
        assert command[3] == "private/login/example"
        return subprocess.CompletedProcess(
            command,
            0,
            b"password\nurl: example.com\nhttps: https://secure.example.com\nnotes: secret-ish\n",
            b"",
        )

    index = refresh_index(
        store_dir=store,
        index_path=index_path,
        field_names=["url", "https"],
        pass_command="/bin/pass",
        runner=fake_runner,
    )

    assert calls == [["/bin/pass", "show", "--", "private/login/example"]]
    assert index == {
        "version": 1,
        "entries": [
            {
                "path": "private/login/example",
                "fields": {
                    "url": ["example.com"],
                    "https": ["https://secure.example.com"],
                },
                "mtime": int((store / "private" / "login" / "example.gpg").stat().st_mtime),
            }
        ],
    }
    assert json.loads(index_path.read_text(encoding="utf-8")) == index


def test_default_index_path_is_under_user_cache(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))

    assert default_index_path() == tmp_path / "cache" / "passff-shared" / "metadata-index.json"
