import asyncio
import threading

import pytest

from daemon import PassffBroker, default_runner, metadata_cache_key, request_label


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


def test_request_label_does_not_log_entry_names():
    assert request_label([]) == "root"
    assert request_label(["example.com/account"]) == "show"
    assert request_label(["grepMetaUrls", ["url"]]) == "grepMetaUrls"
    assert request_label(["otp", "example.com/account"]) == "otp"
    assert request_label(["insert", "example.com/account", "secret"]) == "insert"
    assert request_label(["generate", "example.com/account", "20"]) == "generate"
    assert request_label(["FIREWORKS_API_KEY"]) == "show"


def test_default_runner_answers_grep_meta_urls_from_index(monkeypatch, tmp_path):
    index_path = tmp_path / "metadata-index.json"
    index_path.write_text(
        '{"version":1,"entries":[{"path":"private/login/example","fields":{"url":["https://example.com"]},"mtime":1}]}',
        encoding="utf-8",
    )
    monkeypatch.setenv("PASSFF_SHARED_INDEX_PATH", str(index_path))

    response = run(default_runner(["grepMetaUrls", ["url"]]))

    assert response == {
        "exitCode": 0,
        "stdout": "private/login/example:\nurl: https://example.com\n",
        "stderr": "",
        "version": "1.2.5",
    }


def test_canceled_secret_request_keeps_serialization_until_background_work_finishes():
    events = []
    slow_started = threading.Event()
    release_slow = threading.Event()

    def blocking_slow_response():
        events.append(("start", "slow"))
        slow_started.set()
        release_slow.wait(timeout=1)
        events.append(("end", "slow"))
        return {"exitCode": 0, "stdout": "slow", "stderr": "", "version": "1.2.5"}

    async def runner(message):
        if message[0] == "slow":
            return await asyncio.to_thread(blocking_slow_response)
        events.append(("start", message[0]))
        events.append(("end", message[0]))
        return {"exitCode": 0, "stdout": message[0], "stderr": "", "version": "1.2.5"}

    async def scenario():
        broker = PassffBroker(runner=runner, metadata_ttl_seconds=60)
        with pytest.raises(asyncio.TimeoutError):
            await asyncio.wait_for(broker.handle(["slow"]), timeout=0.02)

        assert await asyncio.to_thread(slow_started.wait, 1)
        second = asyncio.create_task(broker.handle(["second"]))
        await asyncio.sleep(0.05)
        assert events == [("start", "slow")]

        release_slow.set()
        await second
        assert events == [
            ("start", "slow"),
            ("end", "slow"),
            ("start", "second"),
            ("end", "second"),
        ]

    run(scenario())
