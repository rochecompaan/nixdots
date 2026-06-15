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
        self._background_tasks: set[asyncio.Task[Response]] = set()

    async def handle(self, message: list[Any]) -> Response:
        key = metadata_cache_key(message)
        if key is None:
            task = asyncio.create_task(self._run_serialized(message))
            self._track_background_task(task)
            return await asyncio.shield(task)

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
            task.add_done_callback(lambda done, cache_key=key: self._drop_inflight(cache_key, done))
        try:
            response = await asyncio.shield(task)
            return copy.deepcopy(response)
        finally:
            if task.done() and self._inflight.get(key) is task:
                del self._inflight[key]

    async def _run_serialized(self, message: list[Any]) -> Response:
        async with self._lock:
            return await self._runner(message)

    def _track_background_task(self, task: asyncio.Task[Response]) -> None:
        self._background_tasks.add(task)
        task.add_done_callback(self._background_tasks.discard)
        task.add_done_callback(_consume_task_exception)

    def _drop_inflight(self, key: tuple[str, tuple[str, ...]], task: asyncio.Task[Response]) -> None:
        if self._inflight.get(key) is task:
            del self._inflight[key]
        _consume_task_exception(task)

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


def _consume_task_exception(task: asyncio.Task[Response]) -> None:
    if task.cancelled():
        return
    try:
        task.exception()
    except asyncio.CancelledError:
        return


def request_label(message: list[Any]) -> str:
    if not message:
        return "root"
    operation = message[0]
    if operation in {"grepMetaUrls", "otp", "insert", "generate"}:
        return str(operation)
    return "show"


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
            request_type = request_label(message)
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
