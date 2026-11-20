import asyncio
import json
import math
import os
import tempfile
import time
from pathlib import Path

import anyio
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


async def fake_helper(sock, answer, protocol=2):
    """A helper on `sock` that answers the handshake itself (with `protocol`) and other requests with
    `await answer(req, writer)`: a reply dict, or None for none. Returns (server, requests seen, connections
    seen to close)."""
    got, closed = [], []

    async def handle(reader, writer):
        try:
            while line := await reader.readline():
                req = json.loads(line)
                got.append(req)
                if req["cmd"] == "status":
                    reply = {"id": req["id"], "ok": True, "result": {"protocol": protocol} if protocol > 1 else {}}
                else:
                    reply = await answer(req, writer)
                if reply is not None and not writer.is_closing():
                    writer.write(json.dumps(reply).encode() + b"\n")
                    await writer.drain()
        except ConnectionError:
            pass
        finally:
            closed.append(True)

    server = await asyncio.start_unix_server(handle, path=str(sock))
    return server, got, closed


def ok(req, **result):
    return {"id": req["id"], "ok": True, "result": result}


def cmds(got):
    return [g["cmd"] for g in got if g["cmd"] != "status"]


def test_a_request_the_helper_may_have_started_is_not_sent_again(sock):
    async def main():
        async def answer(req, writer):
            writer.close()  # dies mid-request, as a killed helper does

        server, got, _ = await fake_helper(sock, answer)
        h = Helper("t")
        with pytest.raises(HelperError, match="wasn't sent again"):
            await h.call("act", actions=[{"type": "click", "target": "Send"}])
        await asyncio.sleep(0.05)
        server.close()
        return got

    assert cmds(run(main())) == ["act"]


def test_a_connection_that_was_already_gone_is_reopened(sock):
    async def main():
        n = 0

        async def answer(req, writer):
            nonlocal n
            n += 1
            writer.write(json.dumps(ok(req, n=n)).encode() + b"\n")
            await writer.drain()
            if n == 1:
                writer.close()  # answers, then the helper restarts between requests

        server, got, _ = await fake_helper(sock, answer)
        h = Helper("t")
        assert (await h.call("windows"))["n"] == 1
        await asyncio.sleep(0.05)
        assert (await h.call("windows"))["n"] == 2
        server.close()
        return got

    got = run(main())
    assert cmds(got) == ["windows", "windows"]
    assert [g["cmd"] for g in got].count("status") == 2, "each new connection asks which helper it is"


def test_a_cancelled_call_hangs_up_and_the_next_gets_its_own_reply(sock):
    """The bug behind replies arriving one call late: a cancelled call left its reply on the socket."""

    async def main():
        async def answer(req, writer):
            if req["cmd"] == "act":
                await asyncio.sleep(0.3)  # still running when the call is cancelled
                return ok(req, which="act")
            return ok(req, which=req["cmd"])

        server, got, closed = await fake_helper(sock, answer)
        h = Helper("t")
        t = asyncio.create_task(h.call("act", actions=[]))
        await asyncio.sleep(0.1)
        t.cancel()
        with pytest.raises(asyncio.CancelledError):
            await t
        assert h._writer is None, "hung up at once"
        assert (await h.call("windows"))["which"] == "windows"
        await asyncio.sleep(0.4)
        assert closed, "the helper's end of the old connection closed"
        server.close()
        return h, got

    h, got = run(main())
    act = next(g for g in got if g["cmd"] == "act")
    windows = next(g for g in got if g["cmd"] == "windows")
    assert h.lost == set(), "reported"
    assert windows["lost"] == [act["id"]]
    assert act["client"] == windows["client"] == h.client


def test_a_reply_out_of_step_hangs_up(sock):
    async def main():
        async def answer(req, writer):
            return {"id": req["id"] + 100, "ok": True, "result": {}}

        server, _, closed = await fake_helper(sock, answer)
        h = Helper("t")
        with pytest.raises(HelperError, match="another request"):
            await h.call("windows")
        await asyncio.sleep(0.05)
        server.close()
        return closed

    assert run(main())


def test_a_cancel_while_the_request_goes_out_hangs_up():
    closed = []

    class Writer:
        def write(self, b):
            pass

        async def drain(self):
            await asyncio.sleep(10)  # the socket buffer is full

        def close(self):
            closed.append(True)

        def is_closing(self):
            return bool(closed)

    class Reader:
        def at_eof(self):
            return False

    async def main():
        h = Helper("t")
        h._reader, h._writer, h._protocol = Reader(), Writer(), 2
        t = asyncio.create_task(h.call("act", actions=[]))
        await asyncio.sleep(0.05)
        t.cancel()
        with pytest.raises(asyncio.CancelledError):
            await t
        return h

    h = run(main())
    assert closed and h._writer is None


def test_an_old_helper_is_refused_except_for_status_and_quit(sock):
    async def main():
        async def answer(req, writer):
            return ok(req)

        server, got, _ = await fake_helper(sock, answer, protocol=1)
        h = Helper("t")
        with pytest.raises(HelperError, match="out of date.*build-helper.sh"):
            await h.call("act", actions=[])
        with pytest.raises(HelperError, match="out of date"):
            await h.call("windows")  # still the same helper
        await h.call("status")
        await h.call("quit", autostart=False)
        server.close()
        return got

    assert cmds(run(main())) == ["quit"]


def test_quit_returns_once_the_helper_has_exited(sock):
    """The bug: quit replied before the helper was gone, so the next command could reach it as it shut down."""
    import subprocess

    proc = subprocess.Popen(["sleep", "30"])  # stands in for the helper's process

    async def main():
        async def answer(req, writer):
            def exit_():
                proc.kill()
                proc.wait()  # reaped, as launchd does the real one
                server.close()

            asyncio.get_running_loop().call_later(0.2, exit_)  # exits a while after its reply
            return ok(req, pid=proc.pid)

        server, got, _ = await fake_helper(sock, answer)
        t = time.monotonic()
        await Helper("t").quit()
        return time.monotonic() - t, got

    try:
        took, got = run(main())
    finally:
        proc.kill()
        proc.wait()
    assert cmds(got) == ["quit"]
    assert 0.2 <= took < 1, took


def test_quit_says_so_when_the_helper_does_not_exit(sock):
    async def main():
        async def answer(req, writer):
            return ok(req, pid=os.getpid())  # a pid that stays

        server, _, _ = await fake_helper(sock, answer)
        t = time.monotonic()
        with pytest.raises(HelperError, match=f"still running after 0.3 s: stop it with `kill {os.getpid()}`"):
            await Helper("t").quit(timeout=0.3)
        server.close()
        return time.monotonic() - t

    assert run(main()) < 1


def test_quit_of_a_helper_that_does_not_say_its_pid_waits_for_its_socket(sock):
    async def main():
        async def answer(req, writer):
            asyncio.get_running_loop().call_later(0.2, server.close)  # stops listening as it exits
            return ok(req)  # an older helper: no pid

        server, _, _ = await fake_helper(sock, answer)
        t = time.monotonic()
        await Helper("t").quit()
        return time.monotonic() - t

    assert 0.2 <= run(main()) < 1


def test_quit_with_no_helper_running_is_quiet(sock):
    t = time.monotonic()
    run(Helper("t").quit())
    assert time.monotonic() - t < 0.5


def test_reports_go_with_the_next_request_and_clear_once_it_is_answered(sock):
    async def main():
        async def answer(req, writer):
            return ok(req)

        server, got, _ = await fake_helper(sock, answer)
        h = Helper("t")
        h.done.add(7)
        h.lost.add(8)
        await h.call("status")  # the handshake carries no reports
        await h.call("windows")
        await h.call("windows")
        server.close()
        return h, got

    h, got = run(main())
    reqs = [g for g in got if g["cmd"] == "windows"]
    assert "done" not in got[0]
    assert reqs[0]["done"] == [7] and reqs[0]["lost"] == [8]
    assert reqs[1]["done"] == [reqs[0]["id"]] and reqs[1]["lost"] == []
    assert h.done == {reqs[1]["id"]}


def test_a_client_that_cannot_report_says_so(sock):
    async def main():
        async def answer(req, writer):
            return ok(req)

        server, got, _ = await fake_helper(sock, answer)
        h = Helper("t", reports=False)
        await h.call("windows")
        server.close()
        return got

    req = next(g for g in run(main()) if g["cmd"] == "windows")
    assert req["reports"] is False and "done" not in req


def test_a_helper_built_before_its_sources_changed_is_mentioned(sock, monkeypatch, tmp_path):
    src = tmp_path / "helper/Sources/PuterUseHelper"
    src.mkdir(parents=True)
    (tmp_path / "helper/Package.swift").write_text("")
    app = tmp_path / "build/PuterUse.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    binary = app / "Contents/MacOS/PuterUseHelper"
    binary.write_text("")
    (src / "Server.swift").write_text("")
    old = time.time() - 100
    os.utime(binary, (old, old))
    monkeypatch.setattr(client, "_repo", lambda: tmp_path)
    monkeypatch.setattr(client, "app_path", lambda: app)
    assert "built before its latest source changes" in client.stale_build_warning()

    async def main():
        async def answer(req, writer):
            return ok(req)

        server, _, _ = await fake_helper(sock, answer)
        h = Helper("t")
        first, second = await h.call("windows"), await h.call("windows")
        server.close()
        return first, second

    first, second = run(main())
    assert any("rebuild" in n or "build-helper" in n for n in first["notes"]) and "notes" not in second
    os.utime(binary, None)
    assert client.stale_build_warning() is None


def test_a_helper_still_running_an_older_build_is_mentioned(monkeypatch, tmp_path):
    app = tmp_path / "PuterUse.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/PuterUseHelper").write_text("")
    monkeypatch.setattr(client, "app_path", lambda: app)
    now = time.time()
    assert "puter-use quit" in client.restart_warning(now - 100)
    assert client.restart_warning(now + 5) is None
    assert client.restart_warning(None) is None


def test_the_instructions_give_the_command_that_runs_code_mode_here(monkeypatch, tmp_path):
    from puter_use import mcp_server

    assert f"`{client.cli_command()} exec loop.py`" in mcp_server.mcp.instructions
    assert "{cli}" not in mcp_server.mcp.instructions
    checkout = tmp_path / "my code"
    monkeypatch.setattr(client, "_repo", lambda: checkout)
    assert client.cli_command() == f"uv run --project '{checkout}' puter-use"  # cwd kept, path quoted
    monkeypatch.setattr(client, "_repo", lambda: None)
    assert client.cli_command() == "puter-use"


def test_the_instructions_name_every_tool_to_load_at_once():
    from puter_use import mcp_server

    names = [t.name for t in run(mcp_server.mcp.list_tools())]
    hint = mcp_server.mcp.instructions.split("load all six at once: ")[1].split(".")[0]
    assert len(names) == 6 and sorted(hint.split(", ")) == sorted(names)


# -- MCP: which tool calls' results reached the agent


def test_tool_calls_report_their_requests(monkeypatch):
    from mcp.server.mcpserver.exceptions import ToolError

    from puter_use import mcp_server

    h = Helper("t")
    monkeypatch.setattr(mcp_server, "helper", h)
    ids = iter(range(1, 100))

    async def call():  # a tool's helper requests
        client.request_ids.get().append(next(ids))

    @mcp_server.reported
    async def fine():
        await call()
        await call()  # e.g. the consent flow's second act
        return "ok"

    @mcp_server.reported
    async def refused():
        await call()
        raise ToolError("no")

    @mcp_server.reported
    async def slow():
        await call()
        await asyncio.sleep(10)

    @mcp_server.reported
    async def returns_though_cancelled():  # nothing in it waits, so it gets to return
        await call()
        assert anyio.current_effective_deadline() == -math.inf
        return "dropped by the SDK"

    async def main():
        await fine()
        with pytest.raises(ToolError):
            await refused()
        t = asyncio.create_task(slow())
        await asyncio.sleep(0.01)
        t.cancel()
        with pytest.raises(asyncio.CancelledError):
            await t
        with anyio.CancelScope() as scope:  # the SDK's scope for the request, cancelled by the client
            scope.cancel()
            await returns_though_cancelled()

    run(main())
    assert h.done == {1, 2, 3}
    assert h.lost == {4, 5}


def test_overlapping_tool_calls_keep_their_own_requests(monkeypatch):
    from puter_use import mcp_server

    h = Helper("t")
    monkeypatch.setattr(mcp_server, "helper", h)

    @mcp_server.reported
    async def tool(rid, wait, fail):
        client.request_ids.get().append(rid)
        await asyncio.sleep(wait)
        client.request_ids.get().append(rid + 10)
        if fail:
            await asyncio.sleep(10)

    async def main():
        a = asyncio.create_task(tool(1, 0.02, False))
        b = asyncio.create_task(tool(2, 0.01, True))
        await a
        await asyncio.sleep(0.02)
        b.cancel()
        with pytest.raises(asyncio.CancelledError):
            await b

    run(main())
    assert h.done == {1, 11} and h.lost == {2, 12}


def test_the_tools_keep_their_signatures():
    import inspect

    from puter_use.mcp_server import act, screenshot

    assert "ctx" in inspect.signature(act).parameters
    assert inspect.iscoroutinefunction(screenshot) and screenshot.__name__ == "screenshot"


def test_an_empty_result_is_an_error():
    from mcp.server.mcpserver.exceptions import ToolError

    from puter_use.mcp_server import _content

    with pytest.raises(ToolError):
        _content({})
    assert _content({"window": {"id": 1, "app": "X"}})


# -- code mode


def test_ctrl_c_in_a_script_cancels_the_call_and_hangs_up(monkeypatch):
    from puter_use.api import Computer

    pu = Computer("X")
    closed = []

    async def call(cmd, **params):
        try:
            await asyncio.sleep(10)
        except asyncio.CancelledError:
            closed.append("cancelled")
            raise

    monkeypatch.setattr(pu._helper, "call", call)
    monkeypatch.setattr(pu._helper, "drop", lambda: closed.append("dropped"))
    pu._loop.call_later(0.05, lambda: (_ for _ in ()).throw(KeyboardInterrupt))
    with pytest.raises(KeyboardInterrupt):
        pu.windows()
    assert closed == ["cancelled", "dropped"]
    assert not [t for t in asyncio.all_tasks(pu._loop) if not t.done()]
