import subprocess

from passff_logic import build_pass_invocation, run_pass_request, set_pass_gpg_opts


def test_builds_grep_meta_urls_command():
    command, stdin_text = build_pass_invocation(
        ["grepMetaUrls", ["url", "http", "https"]],
        pass_command="/bin/pass",
    )

    assert stdin_text is None
    assert command == [
        "/bin/pass",
        "grep",
        "-iE",
        "--",
        "^(url|http|https):",
    ]


def test_builds_show_command_for_key():
    command, stdin_text = build_pass_invocation(["example/site"], pass_command="/bin/pass")

    assert stdin_text is None
    assert command == ["/bin/pass", "show", "--", "/example/site"]


def test_builds_insert_command_with_stdin():
    command, stdin_text = build_pass_invocation(
        ["insert", "example/site", "secret\nmetadata"],
        pass_command="/bin/pass",
    )

    assert stdin_text == "secret\nmetadata"
    assert command == ["/bin/pass", "insert", "-m", "--", "example/site"]


def test_set_pass_gpg_opts_replaces_existing_debug_and_status_fd():
    env = {"PASSWORD_STORE_GPG_OPTS": "--debug old --status-fd 4 --quiet"}

    set_pass_gpg_opts(env, {"--status-fd": "2", "--debug": "ipc"})

    assert "--status-fd=2" in env["PASSWORD_STORE_GPG_OPTS"]
    assert "--debug=ipc" in env["PASSWORD_STORE_GPG_OPTS"]
    assert "old" not in env["PASSWORD_STORE_GPG_OPTS"]
    assert "--quiet" in env["PASSWORD_STORE_GPG_OPTS"]


def test_run_pass_request_clears_successful_grep_stderr():
    calls = []

    def fake_runner(command, **kwargs):
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0, b"url: https://example.test\n", b"large debug output")

    response = run_pass_request(
        ["grepMetaUrls", ["url"]],
        pass_command="/bin/pass",
        runner=fake_runner,
    )

    assert response == {
        "exitCode": 0,
        "stdout": "url: https://example.test\n",
        "stderr": "",
        "version": "1.2.5",
    }
    assert calls[0][0] == ["/bin/pass", "grep", "-iE", "--", "^(url):"]
