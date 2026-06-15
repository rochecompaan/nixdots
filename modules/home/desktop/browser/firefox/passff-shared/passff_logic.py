import os
import re
import shlex
import subprocess
from collections.abc import Callable, Sequence
from typing import Any

VERSION = "1.2.5"
PASS_COMMAND = os.environ.get("PASSFF_SHARED_PASS_COMMAND", "@PASS_COMMAND@")
COMMAND_ENV = {
    "TREE_CHARSET": "ISO-8859-1",
    "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
}
CHARSET = "UTF-8"

PassRunner = Callable[..., subprocess.CompletedProcess[bytes]]


def set_pass_gpg_opts(env: dict[str, str], opts_dict: dict[str, str | None]) -> None:
    opts = env.get("PASSWORD_STORE_GPG_OPTS", "")
    for opt, value in opts_dict.items():
        re_opt = new_opt = opt
        if value is not None:
            re_opt = rf"{re.escape(opt)}(?:=|\s+)\S*"
            new_opt = f"{opt}={shlex.quote(value)}" if opt.startswith("--") else f"{opt} {shlex.quote(value)}"
        opts = re.sub(re_opt, "", opts)
        opts = f"{new_opt} {opts}"
    env["PASSWORD_STORE_GPG_OPTS"] = opts.strip()


def _key_with_leading_slash(key: str) -> str:
    return "/" + (key[1:] if key.startswith("/") else key)


def build_pass_invocation(
    received_message: list[Any],
    *,
    pass_command: str = PASS_COMMAND,
    command_args: Sequence[str] = (),
) -> tuple[list[str], str | None]:
    opt_args: list[str]
    pos_args: list[str]
    stdin_text: str | None = None

    if len(received_message) == 0:
        opt_args = ["show"]
        pos_args = ["/"]
    elif received_message[0] == "insert":
        opt_args = ["insert", "-m"]
        pos_args = [str(received_message[1])]
        stdin_text = str(received_message[2])
    elif received_message[0] == "generate":
        opt_args = ["generate"]
        pos_args = [str(received_message[1]), str(received_message[2])]
        if "-n" in received_message[3:]:
            opt_args.append("-n")
    elif received_message[0] == "grepMetaUrls" and len(received_message) == 2:
        opt_args = ["grep", "-iE"]
        url_field_names = [str(value) for value in received_message[1]]
        pos_args = ["^({}):".format("|".join(url_field_names))]
    elif received_message[0] == "otp" and len(received_message) == 2:
        opt_args = ["otp"]
        pos_args = [_key_with_leading_slash(str(received_message[1]))]
    else:
        opt_args = ["show"]
        pos_args = [_key_with_leading_slash(str(received_message[0]))]

    opt_args.extend(command_args)
    return [pass_command] + opt_args + ["--"] + pos_args, stdin_text


def command_environment() -> dict[str, str]:
    env = dict(os.environ)
    if "HOME" not in env:
        env["HOME"] = os.path.expanduser("~")
    env.update(COMMAND_ENV)
    set_pass_gpg_opts(env, {"--status-fd": "2", "--debug": "ipc"})
    return env


def run_pass_request(
    received_message: list[Any],
    *,
    pass_command: str = PASS_COMMAND,
    runner: PassRunner = subprocess.run,
) -> dict[str, Any]:
    command, stdin_text = build_pass_invocation(received_message, pass_command=pass_command)
    proc = runner(
        command,
        input=bytes(stdin_text, CHARSET) if stdin_text is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=command_environment(),
    )

    response = {
        "exitCode": proc.returncode,
        "stdout": proc.stdout.decode(CHARSET),
        "stderr": proc.stderr.decode(CHARSET),
        "version": VERSION,
    }

    if proc.returncode == 0 and len(received_message) == 2 and received_message[0] == "grepMetaUrls":
        response["stderr"] = ""

    return response
