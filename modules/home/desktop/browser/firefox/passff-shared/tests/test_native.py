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


def test_decode_two_messages_from_separate_streams():
    first = io.BytesIO(encode_message(["example/site"]))
    second = io.BytesIO(encode_message({"exitCode": 0, "stdout": "secret", "stderr": "", "version": "1.2.5"}))

    assert read_message(first) == ["example/site"]
    assert read_message(second)["stdout"] == "secret"
