"""Client for the PuterUse helper app (JSON lines over a Unix socket), launching it on demand."""

from __future__ import annotations

import asyncio
import itertools
import json
import os
import subprocess
from pathlib import Path

SOCKET = Path(
    os.environ.get("PUTER_USE_SOCKET")
    or Path.home() / "Library/Application Support/puter-use/helper.sock"
)


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


class Helper:
    """One persistent connection; requests are serialized. Every request names the session it belongs
    to (see `settings.session`)."""

    def __init__(self, session: str = "default") -> None:
        self.session = session
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._lock = asyncio.Lock()
        self._ids = itertools.count(1)

    async def _connect(self, autostart: bool = True) -> None:
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

    async def call(self, cmd: str, autostart: bool = True, **params) -> dict:
        params = {k: v for k, v in params.items() if v is not None}
        async with self._lock:
            # A request is sent again only if it can't have reached the helper (the connection was already
            # gone). Once it's sent, a lost reply is an error: the helper may have done part of it, and
            # doing that again (a second Send) would be worse than stopping.
            for attempt in range(2):
                if self._writer is None or self._writer.is_closing() or self._reader.at_eof():
                    await self._connect(autostart)
                req = {"id": next(self._ids), "cmd": cmd, "session": self.session, "params": params}
                try:
                    self._writer.write(json.dumps(req).encode() + b"\n")
                    await self._writer.drain()
                    break
                except (ConnectionError, BrokenPipeError):
                    self._writer = None
                    if attempt:
                        raise HelperError("lost connection to helper")
            try:
                line = await self._reader.readline()
            except (ConnectionError, asyncio.IncompleteReadError):
                line = b""
            if not line:
                self._writer = None
                raise HelperError(f"the helper stopped while running {cmd}: it may have done part of it, so it "
                                  "wasn't sent again. Take a screenshot to see where things stand")
            resp = json.loads(line)
        if not resp.get("ok"):
            raise HelperError(resp.get("error", "unknown helper error"))
        return resp.get("result", {})

    async def close(self) -> None:
        if self._writer:
            self._writer.close()
            self._writer = None
