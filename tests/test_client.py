import asyncio
import json
import tempfile
from pathlib import Path

import pytest

from puter_use import client
from puter_use.client import Helper, HelperError


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


@pytest.fixture
def sock(monkeypatch):
    path = Path(tempfile.mkdtemp()) / "h.sock"  # short: Unix socket paths are limited to ~100 bytes
    monkeypatch.setattr(client, "SOCKET", path)
    return path


def test_a_request_the_helper_may_have_started_is_not_sent_again(sock):
    got = []

    async def main():
        async def handle(reader, writer):
            got.append(json.loads(await reader.readline()))
            writer.close()  # dies mid-request, as a killed helper does

        server = await asyncio.start_unix_server(handle, path=str(sock))
        h = Helper("t")
        with pytest.raises(HelperError, match="wasn't sent again"):
            await h.call("act", actions=[{"type": "click", "target": "Send"}])
        await asyncio.sleep(0.05)
        server.close()

    run(main())
    assert len(got) == 1


def test_a_connection_that_was_already_gone_is_reopened(sock):
    got = []

    async def main():
        async def handle(reader, writer):
            line = await reader.readline()
            if not line:
                return
            got.append(json.loads(line))
            if len(got) == 1:  # answers, then the helper restarts between requests
                writer.write(json.dumps({"id": got[-1]["id"], "ok": True, "result": {"n": 1}}).encode() + b"\n")
                await writer.drain()
                writer.close()
                return
            writer.write(json.dumps({"id": got[-1]["id"], "ok": True, "result": {"n": 2}}).encode() + b"\n")
            await writer.drain()

        server = await asyncio.start_unix_server(handle, path=str(sock))
        h = Helper("t")
        assert (await h.call("windows"))["n"] == 1
        await asyncio.sleep(0.05)
        assert (await h.call("windows"))["n"] == 2
        server.close()

    run(main())
    assert [g["cmd"] for g in got] == ["windows", "windows"]
