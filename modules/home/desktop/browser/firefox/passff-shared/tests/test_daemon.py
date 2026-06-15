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
