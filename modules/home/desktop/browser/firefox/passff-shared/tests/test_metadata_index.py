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


def test_refresh_index_reports_progress_for_full_refresh(tmp_path):
    store = tmp_path / "store"
    (store / "private" / "login").mkdir(parents=True)
    (store / "private" / "login" / "alpha.gpg").write_text("encrypted", encoding="utf-8")
    (store / "private" / "login" / "beta.gpg").write_text("encrypted", encoding="utf-8")
    progress = []

    def fake_runner(command, **kwargs):
        return subprocess.CompletedProcess(command, 0, b"password\nurl: example.com\n", b"")

    refresh_index(
        store_dir=store,
        index_path=tmp_path / "index.json",
        pass_command="/bin/pass",
        runner=fake_runner,
        progress=lambda current, total, entry: progress.append((current, total, entry)),
    )

    assert progress == [
        (1, 2, "private/login/alpha"),
        (2, 2, "private/login/beta"),
    ]


def test_update_index_entries_decrypts_only_requested_entries(tmp_path):
    from metadata_index import update_index_entries

    store = tmp_path / "store"
    (store / "private" / "login").mkdir(parents=True)
    (store / "private" / "login" / "alpha.gpg").write_text("encrypted", encoding="utf-8")
    (store / "private" / "login" / "beta.gpg").write_text("encrypted", encoding="utf-8")
    index_path = tmp_path / "index.json"
    write_index(
        index_path,
        {
            "version": 1,
            "entries": [
                {"path": "private/login/alpha", "fields": {"url": ["https://old.example"]}, "mtime": 1},
                {"path": "private/login/beta", "fields": {"url": ["https://beta.example"]}, "mtime": 2},
            ],
        },
    )
    calls = []

    def fake_runner(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, b"password\nurl: https://new.example\n", b"")

    index = update_index_entries(
        ["private/login/alpha"],
        store_dir=store,
        index_path=index_path,
        pass_command="/bin/pass",
        runner=fake_runner,
    )

    assert calls == [["/bin/pass", "show", "--", "private/login/alpha"]]
    assert index["entries"] == [
        {
            "path": "private/login/beta",
            "fields": {"url": ["https://beta.example"]},
            "mtime": 2,
        },
        {
            "path": "private/login/alpha",
            "fields": {"url": ["https://new.example"]},
            "mtime": int((store / "private" / "login" / "alpha.gpg").stat().st_mtime),
        },
    ]


def test_remove_index_entries_drops_deleted_paths(tmp_path):
    from metadata_index import remove_index_entries

    index_path = tmp_path / "index.json"
    write_index(
        index_path,
        {
            "version": 1,
            "entries": [
                {"path": "private/login/alpha", "fields": {"url": ["https://alpha.example"]}, "mtime": 1},
                {"path": "private/login/beta", "fields": {"url": ["https://beta.example"]}, "mtime": 2},
            ],
        },
    )

    index = remove_index_entries(["private/login/alpha"], index_path=index_path)

    assert index["entries"] == [
        {"path": "private/login/beta", "fields": {"url": ["https://beta.example"]}, "mtime": 2}
    ]


def test_install_git_hooks_writes_executable_local_hooks(tmp_path):
    from metadata_index import install_git_hooks

    store = tmp_path / "store"
    hooks_dir = store / ".git" / "hooks"
    hooks_dir.mkdir(parents=True)

    installed = install_git_hooks(store_dir=store, index_command="/bin/passff-shared-index")

    assert installed == [hooks_dir / "post-commit", hooks_dir / "post-merge"]
    for hook in installed:
        assert hook.exists()
        assert os.access(hook, os.X_OK)
        content = hook.read_text(encoding="utf-8")
        assert "/bin/passff-shared-index" in content
        assert "update --entry" in content
        assert "remove --entry" in content
