import os
import socket
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
            time.sleep(0.1)
        except ConnectionRefusedError as exc:
            last_error = exc
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
