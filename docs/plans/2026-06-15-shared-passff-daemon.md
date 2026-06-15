# Shared PassFF Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shared per-user PassFF daemon/proxy so all niri-launched Firefox profiles share one serialized PassFF backend instead of spawning concurrent `pass`/GPG operations.

**Architecture:** Replace the direct PassFF native host with a tiny native-messaging proxy that forwards requests to one Unix-socket daemon. The daemon preserves PassFF's request/response protocol, serializes secret operations, single-flights duplicate metadata scans, and caches only successful metadata scan responses in memory for a short TTL. It never caches decrypted password, OTP, insert, or generated secret responses.

**Tech Stack:** Python 3 standard library, Firefox native messaging framing, Unix domain sockets, systemd user service/socket, Nix/Home Manager packaging, pytest for protocol/concurrency tests.

---

## File structure

- Create `modules/home/desktop/browser/firefox/passff-shared/native.py`
  - Responsibility: Firefox/native-message framing for sync streams and asyncio streams.
- Create `modules/home/desktop/browser/firefox/passff-shared/passff_logic.py`
  - Responsibility: translate PassFF extension requests into `pass` commands and return PassFF-shaped responses.
- Create `modules/home/desktop/browser/firefox/passff-shared/daemon.py`
  - Responsibility: Unix-socket daemon, request serialization, single-flight metadata scans, metadata TTL cache.
- Create `modules/home/desktop/browser/firefox/passff-shared/proxy.py`
  - Responsibility: one-shot Firefox native host that forwards one request to the shared daemon.
- Create `modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py`
  - Responsibility: native-message framing tests.
- Create `modules/home/desktop/browser/firefox/passff-shared/tests/test_passff_logic.py`
  - Responsibility: request translation and response-shaping tests.
- Create `modules/home/desktop/browser/firefox/passff-shared/tests/test_daemon.py`
  - Responsibility: serialization, single-flight, and metadata cache tests.
- Modify `modules/home/desktop/browser/firefox/default.nix`
  - Responsibility: package the local daemon/proxy, expose a PassFF native host manifest, configure systemd user service/socket, and point Firefox at the shared host.

---

### Task 1: Add native-message framing helpers

**Files:**
- Create: `modules/home/desktop/browser/firefox/passff-shared/native.py`
- Create: `modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py`

- [ ] **Step 1: Create the directory**

Run:

```bash
mkdir -p modules/home/desktop/browser/firefox/passff-shared/tests
```

Expected: command exits 0.

- [ ] **Step 2: Write the framing tests first**

Create `modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py`:

```python
import asyncio
import io
import json
import struct

import pytest

from native import (
    NativeMessageError,
    encode_message,
    read_message,
    write_message,
)


def test_encode_message_uses_native_length_prefix():
    payload = ["grepMetaUrls", ["url", "http"]]

    encoded = encode_message(payload)

    size = struct.unpack("@I", encoded[:4])[0]
    assert size == len(encoded) - 4
    assert json.loads(encoded[4:].decode("utf-8")) == payload


def test_read_message_reads_one_message_from_stream():
    stream = io.BytesIO(encode_message(["show", "example"]))

    assert read_message(stream) == ["show", "example"]


def test_write_message_round_trips_through_read_message():
    stream = io.BytesIO()

    write_message(stream, {"exitCode": 0, "stdout": "ok"})
    stream.seek(0)

    assert read_message(stream) == {"exitCode": 0, "stdout": "ok"}


def test_read_message_rejects_truncated_payload():
    stream = io.BytesIO(struct.pack("@I", 10) + b"short")

    with pytest.raises(NativeMessageError):
        read_message(stream)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py -q
```

Expected: FAIL because `native` does not exist.

- [ ] **Step 4: Implement native framing helpers**

Create `modules/home/desktop/browser/firefox/passff-shared/native.py`:

```python
import asyncio
import json
import struct
from typing import Any, BinaryIO

MAX_MESSAGE_BYTES = 16 * 1024 * 1024


class NativeMessageError(RuntimeError):
    """Raised when a native-message frame is malformed."""


def encode_message(message: Any) -> bytes:
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
    if len(payload) > MAX_MESSAGE_BYTES:
        raise NativeMessageError(f"message too large: {len(payload)} bytes")
    return struct.pack("@I", len(payload)) + payload


def read_message(stream: BinaryIO) -> Any:
    raw_length = stream.read(4)
    if raw_length == b"":
        raise EOFError("no native message available")
    if len(raw_length) != 4:
        raise NativeMessageError("truncated native message length")

    message_length = struct.unpack("@I", raw_length)[0]
    if message_length > MAX_MESSAGE_BYTES:
        raise NativeMessageError(f"message too large: {message_length} bytes")

    payload = stream.read(message_length)
    if len(payload) != message_length:
        raise NativeMessageError("truncated native message payload")
    return json.loads(payload.decode("utf-8"))


def write_message(stream: BinaryIO, message: Any) -> None:
    stream.write(encode_message(message))
    stream.flush()


async def read_async_message(reader: asyncio.StreamReader) -> Any:
    try:
        raw_length = await reader.readexactly(4)
    except asyncio.IncompleteReadError as exc:
        if exc.partial == b"":
            raise EOFError("no native message available") from exc
        raise NativeMessageError("truncated native message length") from exc

    message_length = struct.unpack("@I", raw_length)[0]
    if message_length > MAX_MESSAGE_BYTES:
        raise NativeMessageError(f"message too large: {message_length} bytes")

    try:
        payload = await reader.readexactly(message_length)
    except asyncio.IncompleteReadError as exc:
        raise NativeMessageError("truncated native message payload") from exc
    return json.loads(payload.decode("utf-8"))


async def write_async_message(writer: asyncio.StreamWriter, message: Any) -> None:
    writer.write(encode_message(message))
    await writer.drain()
```

- [ ] **Step 5: Run the native tests**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py -q
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 1**

Run:

```bash
git add modules/home/desktop/browser/firefox/passff-shared/native.py \
  modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py
git commit -m "feat(passff): add native message framing"
```

Expected: signed commit succeeds.

---

### Task 2: Add PassFF request translation and command runner

**Files:**
- Create: `modules/home/desktop/browser/firefox/passff-shared/passff_logic.py`
- Create: `modules/home/desktop/browser/firefox/passff-shared/tests/test_passff_logic.py`

- [ ] **Step 1: Write request translation tests**

Create `modules/home/desktop/browser/firefox/passff-shared/tests/test_passff_logic.py`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests/test_passff_logic.py -q
```

Expected: FAIL because `passff_logic` does not exist.

- [ ] **Step 3: Implement PassFF logic**

Create `modules/home/desktop/browser/firefox/passff-shared/passff_logic.py`:

```python
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
```

- [ ] **Step 4: Run PassFF logic tests**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests/test_passff_logic.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Run all Python tests so far**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests -q
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 2**

Run:

```bash
git add modules/home/desktop/browser/firefox/passff-shared/passff_logic.py \
  modules/home/desktop/browser/firefox/passff-shared/tests/test_passff_logic.py
git commit -m "feat(passff): translate shared host requests"
```

Expected: signed commit succeeds.

---

### Task 3: Add daemon broker with serialization, single-flight, and cache

**Files:**
- Create: `modules/home/desktop/browser/firefox/passff-shared/daemon.py`
- Create: `modules/home/desktop/browser/firefox/passff-shared/tests/test_daemon.py`

- [ ] **Step 1: Write broker tests**

Create `modules/home/desktop/browser/firefox/passff-shared/tests/test_daemon.py`:

```python
import asyncio

from daemon import PassffBroker, metadata_cache_key


def run(coro):
    return asyncio.run(coro)


def test_metadata_cache_key_normalizes_grep_meta_urls():
    assert metadata_cache_key(["grepMetaUrls", ["url", "http"]]) == ("grepMetaUrls", ("url", "http"))
    assert metadata_cache_key(["example/site"]) is None


def test_broker_serializes_secret_operations():
    events = []

    async def runner(message):
        events.append(("start", message[0]))
        await asyncio.sleep(0.01)
        events.append(("end", message[0]))
        return {"exitCode": 0, "stdout": message[0], "stderr": "", "version": "1.2.5"}

    async def scenario():
        broker = PassffBroker(runner=runner, metadata_ttl_seconds=60)
        await asyncio.gather(broker.handle(["one"]), broker.handle(["two"]), broker.handle(["three"]))

    run(scenario())

    assert events == [
        ("start", "one"),
        ("end", "one"),
        ("start", "two"),
        ("end", "two"),
        ("start", "three"),
        ("end", "three"),
    ]


def test_broker_single_flights_duplicate_metadata_scans():
    calls = []

    async def runner(message):
        calls.append(message)
        await asyncio.sleep(0.01)
        return {"exitCode": 0, "stdout": "url: https://example.test\n", "stderr": "", "version": "1.2.5"}

    async def scenario():
        broker = PassffBroker(runner=runner, metadata_ttl_seconds=60)
        results = await asyncio.gather(
            broker.handle(["grepMetaUrls", ["url"]]),
            broker.handle(["grepMetaUrls", ["url"]]),
            broker.handle(["grepMetaUrls", ["url"]]),
        )
        assert results[0] == results[1] == results[2]

    run(scenario())

    assert len(calls) == 1


def test_broker_uses_metadata_cache_for_successful_grep():
    calls = []

    async def runner(message):
        calls.append(message)
        return {"exitCode": 0, "stdout": "url: https://example.test\n", "stderr": "", "version": "1.2.5"}

    async def scenario():
        broker = PassffBroker(runner=runner, metadata_ttl_seconds=60)
        first = await broker.handle(["grepMetaUrls", ["url"]])
        second = await broker.handle(["grepMetaUrls", ["url"]])
        assert first == second

    run(scenario())

    assert len(calls) == 1


def test_broker_does_not_cache_show_requests():
    calls = []

    async def runner(message):
        calls.append(message)
        return {"exitCode": 0, "stdout": "secret", "stderr": "", "version": "1.2.5"}

    async def scenario():
        broker = PassffBroker(runner=runner, metadata_ttl_seconds=60)
        await broker.handle(["example/site"])
        await broker.handle(["example/site"])

    run(scenario())

    assert len(calls) == 2
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests/test_daemon.py -q
```

Expected: FAIL because `daemon` does not exist.

- [ ] **Step 3: Implement daemon and broker**

Create `modules/home/desktop/browser/firefox/passff-shared/daemon.py`:

```python
import argparse
import asyncio
import copy
import os
import socket
import sys
import tempfile
import time
from collections.abc import Awaitable, Callable
from typing import Any

from native import NativeMessageError, read_async_message, write_async_message
from passff_logic import PASS_COMMAND, VERSION, run_pass_request

Response = dict[str, Any]
AsyncRunner = Callable[[list[Any]], Awaitable[Response]]


def default_socket_path() -> str:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", tempfile.gettempdir())
    return os.environ.get("PASSFF_SHARED_SOCKET", os.path.join(runtime_dir, "passff-shared.sock"))


def metadata_cache_key(message: list[Any]) -> tuple[str, tuple[str, ...]] | None:
    if len(message) == 2 and message[0] == "grepMetaUrls" and isinstance(message[1], list):
        return ("grepMetaUrls", tuple(str(value) for value in message[1]))
    return None


async def default_runner(message: list[Any]) -> Response:
    return await asyncio.to_thread(run_pass_request, message, pass_command=PASS_COMMAND)


class PassffBroker:
    def __init__(self, *, runner: AsyncRunner = default_runner, metadata_ttl_seconds: float = 60.0):
        self._runner = runner
        self._metadata_ttl_seconds = metadata_ttl_seconds
        self._lock = asyncio.Lock()
        self._metadata_cache: dict[tuple[str, tuple[str, ...]], tuple[float, Response]] = {}
        self._inflight: dict[tuple[str, tuple[str, ...]], asyncio.Task[Response]] = {}

    async def handle(self, message: list[Any]) -> Response:
        key = metadata_cache_key(message)
        if key is None:
            async with self._lock:
                return await self._runner(message)

        now = time.monotonic()
        cached = self._metadata_cache.get(key)
        if cached is not None:
            expires_at, response = cached
            if now < expires_at:
                return copy.deepcopy(response)
            del self._metadata_cache[key]

        task = self._inflight.get(key)
        if task is None:
            task = asyncio.create_task(self._run_metadata_scan(key, message))
            self._inflight[key] = task
        try:
            response = await asyncio.shield(task)
            return copy.deepcopy(response)
        finally:
            if task.done() and self._inflight.get(key) is task:
                del self._inflight[key]

    async def _run_metadata_scan(self, key: tuple[str, tuple[str, ...]], message: list[Any]) -> Response:
        async with self._lock:
            response = await self._runner(message)
        if response.get("exitCode") == 0:
            self._metadata_cache[key] = (time.monotonic() + self._metadata_ttl_seconds, copy.deepcopy(response))
        return response


def activated_socket() -> socket.socket | None:
    listen_pid = int(os.environ.get("LISTEN_PID", "0") or "0")
    listen_fds = int(os.environ.get("LISTEN_FDS", "0") or "0")
    if listen_fds != 1:
        return None
    if listen_pid not in (0, os.getpid()):
        return None
    sock = socket.socket(fileno=3)
    sock.set_inheritable(False)
    return sock


def error_response(message: str) -> Response:
    return {"exitCode": 1, "stdout": "", "stderr": f"passff-shared-daemon: {message}", "version": VERSION}


async def handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    broker: PassffBroker,
    request_timeout: float,
) -> None:
    try:
        message = await asyncio.wait_for(read_async_message(reader), timeout=request_timeout)
        if not isinstance(message, list):
            response = error_response("request must be a JSON array")
        else:
            start = time.monotonic()
            response = await asyncio.wait_for(broker.handle(message), timeout=request_timeout)
            duration_ms = int((time.monotonic() - start) * 1000)
            request_type = message[0] if message else "root"
            print(
                f"passff-shared-daemon request={request_type} exit={response.get('exitCode')} duration_ms={duration_ms}",
                file=sys.stderr,
                flush=True,
            )
    except (asyncio.TimeoutError, EOFError, NativeMessageError) as exc:
        response = error_response(str(exc))
    except Exception as exc:
        response = error_response(f"unexpected error: {exc}")

    try:
        await write_async_message(writer, response)
    finally:
        writer.close()
        await writer.wait_closed()


async def serve(args: argparse.Namespace) -> None:
    broker = PassffBroker(metadata_ttl_seconds=args.metadata_ttl)
    sock = activated_socket()
    if sock is not None:
        server = await asyncio.start_unix_server(
            lambda reader, writer: handle_client(reader, writer, broker, args.request_timeout),
            sock=sock,
        )
    else:
        if os.path.exists(args.socket):
            os.unlink(args.socket)
        server = await asyncio.start_unix_server(
            lambda reader, writer: handle_client(reader, writer, broker, args.request_timeout),
            path=args.socket,
        )
        os.chmod(args.socket, 0o600)

    async with server:
        await server.serve_forever()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Shared PassFF daemon")
    parser.add_argument("--socket", default=default_socket_path())
    parser.add_argument("--metadata-ttl", type=float, default=float(os.environ.get("PASSFF_SHARED_METADATA_TTL", "60")))
    parser.add_argument("--request-timeout", type=float, default=float(os.environ.get("PASSFF_SHARED_REQUEST_TIMEOUT", "60")))
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args(sys.argv[1:])
    try:
        asyncio.run(serve(args))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run daemon tests**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests/test_daemon.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Run all Python tests**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests -q
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 3**

Run:

```bash
git add modules/home/desktop/browser/firefox/passff-shared/daemon.py \
  modules/home/desktop/browser/firefox/passff-shared/tests/test_daemon.py
git commit -m "feat(passff): add shared request daemon"
```

Expected: signed commit succeeds.

---

### Task 4: Add native-messaging proxy

**Files:**
- Create: `modules/home/desktop/browser/firefox/passff-shared/proxy.py`
- Modify: `modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py`

- [ ] **Step 1: Add proxy integration helpers to the native tests**

Append this test to `modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py`:

```python

def test_decode_two_messages_from_separate_streams():
    first = io.BytesIO(encode_message(["example/site"]))
    second = io.BytesIO(encode_message({"exitCode": 0, "stdout": "secret", "stderr": "", "version": "1.2.5"}))

    assert read_message(first) == ["example/site"]
    assert read_message(second)["stdout"] == "secret"
```

- [ ] **Step 2: Run native tests**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py -q
```

Expected: all tests pass because this extends already implemented framing behavior.

- [ ] **Step 3: Implement proxy**

Create `modules/home/desktop/browser/firefox/passff-shared/proxy.py`:

```python
import os
import socket
import subprocess
import sys
import tempfile
import time
from typing import Any

from native import NativeMessageError, read_message, write_message
from passff_logic import VERSION

DEFAULT_DAEMON = "@PASSFF_SHARED_DAEMON@"


def socket_path() -> str:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", tempfile.gettempdir())
    return os.environ.get("PASSFF_SHARED_SOCKET", os.path.join(runtime_dir, "passff-shared.sock"))


def error_response(message: str) -> dict[str, Any]:
    return {"exitCode": 1, "stdout": "", "stderr": f"passff-shared-proxy: {message}", "version": VERSION}


def connect_socket(path: str) -> socket.socket:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(path)
    return client


def start_daemon(path: str) -> None:
    daemon = os.environ.get("PASSFF_SHARED_DAEMON", DEFAULT_DAEMON)
    if not daemon or daemon.startswith("@"):
        return
    subprocess.Popen(
        [daemon, "--socket", path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def send_to_daemon(message: Any, path: str) -> Any:
    last_error: OSError | None = None
    for attempt in range(8):
        try:
            client = connect_socket(path)
            with client:
                stream = client.makefile("rwb", buffering=0)
                write_message(stream, message)
                return read_message(stream)
        except FileNotFoundError as exc:
            last_error = exc
            if attempt == 0:
                start_daemon(path)
            time.sleep(0.1)
        except ConnectionRefusedError as exc:
            last_error = exc
            if attempt == 0:
                start_daemon(path)
            time.sleep(0.1)
    if last_error is None:
        raise RuntimeError("daemon connection failed")
    raise last_error


def main() -> int:
    try:
        request = read_message(sys.stdin.buffer)
        response = send_to_daemon(request, socket_path())
    except (EOFError, NativeMessageError, OSError, RuntimeError) as exc:
        response = error_response(str(exc))
    write_message(sys.stdout.buffer, response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run all Python tests**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests -q
```

Expected: all tests pass.

- [ ] **Step 5: Run Python syntax checks**

Run:

```bash
nix shell nixpkgs#python3 -c python -m py_compile \
  modules/home/desktop/browser/firefox/passff-shared/native.py \
  modules/home/desktop/browser/firefox/passff-shared/passff_logic.py \
  modules/home/desktop/browser/firefox/passff-shared/daemon.py \
  modules/home/desktop/browser/firefox/passff-shared/proxy.py
```

Expected: exits 0.

- [ ] **Step 6: Commit Task 4**

Run:

```bash
git add modules/home/desktop/browser/firefox/passff-shared/proxy.py \
  modules/home/desktop/browser/firefox/passff-shared/tests/test_native.py
git commit -m "feat(passff): add native host proxy"
```

Expected: signed commit succeeds.

---

### Task 5: Package the shared host in Home Manager

**Files:**
- Modify: `modules/home/desktop/browser/firefox/default.nix`

- [ ] **Step 1: Inspect the current Firefox native host block**

Run:

```bash
rg -n "passWithOtp|passffHostWithOtp|nativeMessagingHosts|firefoxWithPassff|systemd.user" modules/home/desktop/browser/firefox/default.nix
```

Expected: shows the existing `passWithOtp`, `passffHostWithOtp`, `firefoxWithPassff`, and no current shared daemon service.

- [ ] **Step 2: Replace the host derivation and add systemd units**

Modify `modules/home/desktop/browser/firefox/default.nix` as follows:

1. Keep `passWithOtp`.
2. Replace `passffHostWithOtp` with `passffSharedHost`.
3. Point `nativeMessagingHosts` at `passffSharedHost`.
4. Add `systemd.user.sockets.passff-shared` and `systemd.user.services.passff-shared` in the module body.

Use this Nix block in the `let` section after `passWithOtp`:

```nix
  passffSharedHost = pkgs.stdenvNoCC.mkDerivation {
    pname = "passff-shared-host";
    version = "0.1.0";
    src = ./passff-shared;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib/passff-shared $out/bin $out/share/passff-host
      cp native.py passff_logic.py daemon.py proxy.py $out/lib/passff-shared/

      substituteInPlace $out/lib/passff-shared/passff_logic.py \
        --replace-fail '@PASS_COMMAND@' '${passWithOtp}/bin/pass'
      substituteInPlace $out/lib/passff-shared/proxy.py \
        --replace-fail '@PASSFF_SHARED_DAEMON@' "$out/bin/passff-shared-daemon"

      makeWrapper ${pkgs.python3}/bin/python3 $out/bin/passff-shared-daemon \
        --add-flags "$out/lib/passff-shared/daemon.py" \
        --set PASSFF_SHARED_PASS_COMMAND '${passWithOtp}/bin/pass'

      makeWrapper ${pkgs.python3}/bin/python3 $out/bin/passff-shared-proxy \
        --add-flags "$out/lib/passff-shared/proxy.py" \
        --set PASSFF_SHARED_DAEMON "$out/bin/passff-shared-daemon"

      cat > $out/share/passff-host/passff.json <<JSON
      {
        "name": "passff",
        "description": "Shared host for communicating with zx2c4 pass",
        "path": "$out/bin/passff-shared-proxy",
        "type": "stdio",
        "allowed_extensions": [ "passff@invicem.pro" ]
      }
JSON

      runHook postInstall
    '';
  };
```

Change the Firefox package override to:

```nix
  firefoxWithPassff = pkgs.firefox.override {
    nativeMessagingHosts = [ passffSharedHost ];
  };
```

Add this module-level attribute near the existing `programs.firefox` configuration:

```nix
  systemd.user.sockets.passff-shared = {
    Unit.Description = "Shared PassFF daemon socket";
    Socket = {
      ListenStream = "%t/passff-shared.sock";
      SocketMode = "0600";
      RemoveOnStop = true;
    };
    Install.WantedBy = [ "sockets.target" ];
  };

  systemd.user.services.passff-shared = {
    Unit.Description = "Shared PassFF daemon";
    Service = {
      ExecStart = "${passffSharedHost}/bin/passff-shared-daemon";
      Environment = [
        "PASSFF_SHARED_PASS_COMMAND=${passWithOtp}/bin/pass"
        "PASSFF_SHARED_METADATA_TTL=60"
        "PASSFF_SHARED_REQUEST_TIMEOUT=60"
      ];
    };
  };
```

- [ ] **Step 3: Format the Nix file**

Run:

```bash
nix fmt modules/home/desktop/browser/firefox/default.nix
```

Expected: exits 0.

- [ ] **Step 4: Run Python tests again**

Run:

```bash
nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests -q
```

Expected: all tests pass.

- [ ] **Step 5: Build the affected Home Manager activation package**

Run:

```bash
nix build .#homeConfigurations."roche@kipchoge".activationPackage --no-link
```

Expected: build succeeds and includes the new `passff-shared-host` derivation.

- [ ] **Step 6: Commit Task 5**

Run:

```bash
git add modules/home/desktop/browser/firefox/default.nix \
  modules/home/desktop/browser/firefox/passff-shared
git commit -m "feat(passff): package shared native host"
```

Expected: signed commit succeeds.

---

### Task 6: Local runtime verification

**Files:**
- No source changes unless verification reveals a defect.

- [ ] **Step 1: Activate the Home Manager generation**

Run:

```bash
home-manager switch --flake .#roche@kipchoge
```

Expected: activation succeeds; systemd user socket unit is installed.

- [ ] **Step 2: Check the socket unit**

Run:

```bash
systemctl --user daemon-reload
systemctl --user start passff-shared.socket
systemctl --user status passff-shared.socket --no-pager
```

Expected: socket is active and listening on `%t/passff-shared.sock`.

- [ ] **Step 3: Check the native host manifest points to the proxy**

Run:

```bash
find ~/.mozilla -path '*native-messaging-hosts*passff*.json' -print -exec jq . {} \;
```

Expected: the PassFF manifest has `"path"` ending in `passff-shared-proxy`.

- [ ] **Step 4: Start all Firefox profiles through the niri script**

Run from inside a niri session:

```bash
niri-firefox-profiles
```

Expected: all configured profiles launch.

- [ ] **Step 5: Confirm one shared daemon and no PassFF process storm**

Run:

```bash
pgrep -a 'passff-shared|passff-host|pass-wrapped|\.pass-wrapped|pinentry|scdaemon'
```

Expected: at most one `passff-shared-daemon`; no large burst of simultaneous `.pass-wrapped grep` processes; no repeated `pinentry` prompts during startup.

- [ ] **Step 6: Verify CLI pass responsiveness**

Run:

```bash
start=$(date +%s%3N); pass show FIREWORKS_API_KEY >/dev/null; end=$(date +%s%3N); echo "$((end - start)) ms"
```

Expected: completes without repeated prompts. Runtime should be much closer to a single YubiKey decrypt than the previous multi-profile contention case.

- [ ] **Step 7: Verify PassFF from two profiles**

In two different Firefox profiles:

1. Open a site with a saved password.
2. Trigger PassFF fill manually.
3. Confirm the password fills.
4. Confirm only one PIN prompt appears when the card PIN is needed.

Expected: both profiles can use PassFF and do not trigger a prompt storm.

- [ ] **Step 8: Inspect daemon logs**

Run:

```bash
journalctl --user -u passff-shared.service --since '10 minutes ago' --no-pager
```

Expected: logs show request type, exit code, and duration only; logs do not include decrypted password contents.

- [ ] **Step 9: Commit runtime adjustments if needed**

If verification required source changes, run the relevant test/build commands again and commit the adjustment with a concise Conventional Commits subject.

---

## Final verification checklist

- [ ] `nix shell nixpkgs#python3 nixpkgs#python3Packages.pytest -c pytest modules/home/desktop/browser/firefox/passff-shared/tests -q` passes.
- [ ] `nix fmt modules/home/desktop/browser/firefox/default.nix modules/nixos/opt/desktop/services.nix` exits 0.
- [ ] `nix build .#homeConfigurations."roche@kipchoge".activationPackage --no-link` succeeds.
- [ ] `nix build .#nixosConfigurations.kipchoge.config.system.build.toplevel --no-link` succeeds if the existing udev fix remains in the branch.
- [ ] All Firefox profiles still launch through niri.
- [ ] PassFF works from at least two profiles.
- [ ] No repeated PIN prompt storm occurs during Firefox startup.
- [ ] The shared daemon logs do not include secret output.
