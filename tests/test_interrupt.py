"""Ctrl-C in the CLI: one line, exit status 130, no traceback, and the helper's request is cancelled (the
connection closes, which the helper takes as a cancel). Run against a stand-in helper socket that answers
`status` and then never answers the request, as a long wait_for wouldn't."""

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

import pytest


class SilentHelper:
    """A Unix socket that takes one connection, answers its `status`, records the next request, and then
    waits for the client to hang up."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="pu-int-", dir="/tmp")  # short: socket paths are limited
        self.path = os.path.join(self.dir, "h.sock")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(1)
        self.request: dict | None = None
        self.got = threading.Event()
        self.hung_up = threading.Event()
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        conn, _ = self.server.accept()
        buf = b""
        with conn:
            while True:
                data = conn.recv(65536)
                if not data:
                    self.hung_up.set()
                    return
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    req = json.loads(line)
                    if req["cmd"] == "status":
                        conn.sendall(json.dumps({"id": req["id"], "ok": True, "result": {"protocol": 2}}).encode() + b"\n")
                    else:
                        self.request = req
                        self.got.set()

    def close(self):
        self.server.close()
        os.unlink(self.path)
        os.rmdir(self.dir)


def interrupt(args: list[str], ignore_sigint: bool = False):
    helper = SilentHelper()
    env = {**os.environ, "PUTER_USE_SOCKET": helper.path}
    env.pop("PUTER_USE_TRACE", None)
    proc = subprocess.Popen(
        [sys.executable, "-c", "from puter_use.cli import main; main()", *args], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        # A background job of a non-interactive shell starts with SIGINT ignored.
        preexec_fn=(lambda: signal.signal(signal.SIGINT, signal.SIG_IGN)) if ignore_sigint else None)
    try:
        assert helper.got.wait(20), "the request never reached the helper"
        sent = time.monotonic()
        proc.send_signal(signal.SIGINT)
        out, err = proc.communicate(timeout=10)
        hung_up = helper.hung_up.wait(5)
        return proc.returncode, out, err, helper.request, hung_up, time.monotonic() - sent
    finally:
        if proc.poll() is None:
            proc.kill()
        helper.close()


@pytest.mark.parametrize("ignored", [False, True])
def test_ctrl_c_stops_the_cli_and_cancels_the_request(ignored):
    code, out, err, req, hung_up, took = interrupt(["wait-for", "Never shows up", "--timeout-ms", "20000", "-w", "9"],
                                                   ignore_sigint=ignored)
    assert req["cmd"] == "act" and req["params"]["actions"][0]["type"] == "wait_for"
    assert code == 130
    assert err == "stopped: interrupted\n" and "Traceback" not in err and out == ""
    assert hung_up, "the connection stayed open: the helper would have kept waiting"
    assert took < 5


def test_ctrl_c_stops_a_script():
    code, out, err, req, hung_up, _ = interrupt(["exec", "-w", "9", "-c",
                                                 "pu.wait_for('Never shows up', timeout_ms=20000)\nprint('after')"])
    assert req["cmd"] == "act"
    assert code == 130 and err == "stopped: interrupted\n" and "after" not in out
    assert hung_up
