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
