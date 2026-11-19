"""Client for the PuterUse helper app (JSON lines over a Unix socket), launching it on demand."""

from __future__ import annotations

import asyncio
import contextvars
import itertools
import json
import os
import subprocess
import uuid
from pathlib import Path

SOCKET = Path(
    os.environ.get("PUTER_USE_SOCKET")
    or Path.home() / "Library/Application Support/puter-use/helper.sock"
)

# The helper protocol this client speaks; the helper says its own in `status`. 2: a client that hangs up
# cancels its request, and requests carry delivery reports (`done`/`lost`).
PROTOCOL = 2
# Commands that work with any helper and take no part in delivery reports.
EXEMPT = {"status", "quit", "permissions"}

# The helper request ids made during the current MCP tool call (see mcp_server.reported), so the call can
# report them delivered or lost once it knows.
request_ids: contextvars.ContextVar[list[int] | None] = contextvars.ContextVar("puter_use_request_ids", default=None)


class HelperError(Exception):
    pass


def app_path() -> Path:
    candidates = [
        os.environ.get("PUTER_USE_APP"),
        Path(__file__).resolve().parents[2] / "build/PuterUse.app",
        Path.home() / "Applications/PuterUse.app",
    ]
    for c in candidates:
        if c and Path(c, "Contents/MacOS/PuterUseHelper").exists():
            return Path(c)
    raise HelperError("PuterUse.app not found: run scripts/build-helper.sh (or set PUTER_USE_APP)")


def _repo() -> Path | None:
    """The checkout this package runs from, if it's one (it has the helper's sources)."""
    root = Path(__file__).resolve().parents[2]
    return root if (root / "helper/Sources/PuterUseHelper").is_dir() else None


def rebuild_hint() -> str:
    root = _repo()
    if root is None:
        return "reinstall puter-use, then run `puter-use quit` (the next call starts the new helper)"
    return f"run `{root}/scripts/build-helper.sh && uv run --directory {root} puter-use quit`"


def stale_build_warning() -> str | None:
    """In a checkout: a note if the helper app was built before its latest source changes."""
    root = _repo()
    if root is None:
        return None
    try:
        built = (app_path() / "Contents/MacOS/PuterUseHelper").stat().st_mtime
    except (HelperError, OSError):
        return None
    sources = [root / "helper/Package.swift", *(root / "helper/Sources/PuterUseHelper").rglob("*.swift")]
    newest = max((p.stat().st_mtime for p in sources if p.exists()), default=0)
    if newest <= built:
        return None
    return f"the helper was built before its latest source changes: {rebuild_hint()}"


def restart_warning(built: float | None) -> str | None:
    """A note if the helper app was rebuilt since the running helper started (it runs the old build)."""
    if not built:
        return None
    try:
        on_disk = (app_path() / "Contents/MacOS/PuterUseHelper").stat().st_mtime
    except (HelperError, OSError):
        return None
    if on_disk <= built + 1:
        return None
    return "the running helper is older than the one built since: run `puter-use quit` (the next call starts the new one)"


class Helper:
    """One persistent connection; requests are serialized. Every request names the session it belongs
    to (see `settings.session`), and the client (a uuid per Helper) and id it has there.

    A call that's cancelled once its request is out (its agent was interrupted, it timed out) closes the
    connection: the helper takes that as a cancel and stops the batch at its next step, and the next
    call reconnects. Replies are never read by the wrong call.

    Delivery reports: `done` and `lost` hold this client's request ids whose replies did and didn't
    reach the agent. They go with the next request, so the helper can take back what a lost call
    recorded as shown and tell the agent what it did. Who fills them: mcp_server.reported for MCP tool
    calls; otherwise `call` itself (a reply returned is delivered). `reports=False` (one-shot CLI
    processes) leaves it to the helper: a reply it writes counts as delivered.
    """

    def __init__(self, session: str = "default", reports: bool = True) -> None:
        self.session = session
        self.client = uuid.uuid4().hex
        self.reports = reports
        self.done: set[int] = set()
        self.lost: set[int] = set()
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._lock = asyncio.Lock()
        self._ids = itertools.count(1)
        self._protocol: int | None = None  # the connected helper's, once asked
        self._warning = stale_build_warning()

    async def _connect(self, autostart: bool = True) -> None:
        self._protocol = None
        try:
            self._reader, self._writer = await asyncio.open_unix_connection(str(SOCKET), limit=64 << 20)
            return
        except (FileNotFoundError, ConnectionRefusedError):
            if not autostart:
                raise HelperError("helper is not running")
        # -g: don't bring anything to the foreground. The app is LSUIElement (no Dock icon).
        subprocess.run(["open", "-g", str(app_path())], check=True)
        for _ in range(100):
            await asyncio.sleep(0.1)
            try:
                self._reader, self._writer = await asyncio.open_unix_connection(str(SOCKET), limit=64 << 20)
                return
            except (FileNotFoundError, ConnectionRefusedError):
                continue
        raise HelperError(f"helper did not start (socket {SOCKET})")

    def _drop(self) -> None:
        """Close the connection now, without awaiting (a cancelled task can't): the helper takes the
        hang-up as a cancel of whatever it's running for us."""
        if self._writer is not None:
            try:
                self._writer.close()
            except Exception:
                pass
        self._reader = self._writer = None
        self._protocol = None

    def drop(self) -> None:
        self._drop()

    def _connected(self) -> bool:
        return not (self._writer is None or self._writer.is_closing() or self._reader is None or self._reader.at_eof())

    async def _send(self, req: dict) -> bool:
        """Write a request. False if the connection was already gone, so it can't have reached the helper.
        A cancel while it's going out closes the connection (the helper may have it)."""
        try:
            self._writer.write(json.dumps(req).encode() + b"\n")
            await self._writer.drain()
            return True
        except (ConnectionError, BrokenPipeError):
            self._drop()
            return False
        except BaseException:
            self._drop()
            raise

    async def _reply(self, req: dict) -> dict:
        """Read the reply to `req`. Anything that stops the wait (a cancel, a lost connection, a reply out
        of step) closes the connection: the next call reconnects, and never reads another's reply."""
        try:
            line = await self._reader.readline()
        except (ConnectionError, asyncio.IncompleteReadError):
            line = b""
        except BaseException:
            self._drop()
            raise
        if not line:
            self._drop()
            raise HelperError(f"the helper stopped while running {req['cmd']}: it may have done part of it, so it "
                              "wasn't sent again. Take a screenshot to see where things stand")
        try:
            resp = json.loads(line)
        except ValueError:
            self._drop()
            raise HelperError("the helper's reply wasn't readable") from None
        if resp.get("id") != req["id"]:
            self._drop()
            raise HelperError(f"the helper's reply was for another request ({resp.get('id')}, not {req['id']}); "
                              "reconnecting. Take a screenshot to see where things stand")
        return resp

    async def _deliver(self, req: dict, tracked: bool, autostart: bool) -> None:
        """Get `req` to the helper, connecting (and on a new connection, checking the helper's protocol
        unless the command works with any) as needed. A request is sent again only if it can't have
        reached the helper (the connection was already gone). Once it's sent, a lost reply is an error:
        the helper may have done part of it, and doing that again (a second Send) would be worse."""
        for attempt in range(2):
            if not self._connected():
                await self._connect(autostart)
            if tracked and self._protocol is None:  # a new connection: which helper is this?
                hello = {"id": next(self._ids), "client": self.client, "cmd": "status", "session": self.session,
                         "params": {}}
                if not await self._send(hello):
                    if attempt:
                        raise HelperError("lost connection to helper")
                    continue
                info = (await self._reply(hello)).get("result") or {}
                self._protocol = int(info.get("protocol") or 1)
                if self._warning is None and (restart := restart_warning(info.get("built"))):
                    self._warning = restart
            if tracked and self._protocol < PROTOCOL:
                raise HelperError(f"puter-use's helper is out of date (protocol {self._protocol}, this needs "
                                  f"{PROTOCOL}): {rebuild_hint()}")
            if await self._send(req):
                return
            if attempt:
                raise HelperError("lost connection to helper")

    async def call(self, cmd: str, autostart: bool = True, **params) -> dict:
        params = {k: v for k, v in params.items() if v is not None}
        tracked = cmd not in EXEMPT
        async with self._lock:
            rid = next(self._ids)
            req = {"id": rid, "client": self.client, "cmd": cmd, "session": self.session, "params": params}
            done, lost = sorted(self.done), sorted(self.lost)
            if tracked:
                if self.reports:
                    req["done"], req["lost"] = done, lost
                else:
                    req["reports"] = False
                if (ids := request_ids.get()) is not None:
                    ids.append(rid)
            try:
                await self._deliver(req, tracked, autostart)
                resp = await self._reply(req)
            except BaseException:
                # Not inside a tool call, this call decides: the reply never got here.
                if tracked and self.reports and request_ids.get() is None:
                    self.lost.add(rid)
                raise
            if tracked and self.reports:
                self.done.difference_update(done)  # the helper has them now
                self.lost.difference_update(lost)
                if request_ids.get() is None:
                    self.done.add(rid)
        if not resp.get("ok"):
            raise HelperError(resp.get("error", "unknown helper error"))
        result = resp.get("result", {})
        if tracked and self._warning and isinstance(result, dict):
            result.setdefault("notes", []).append(self._warning)
            self._warning = None
        return result

    async def close(self) -> None:
        self._drop()
