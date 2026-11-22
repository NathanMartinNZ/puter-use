"""Code mode: drive apps from a Python script, for the loops and branches that would otherwise cost
a model call per step. `puter-use exec script.py` runs a script with `pu` (a Computer) ready.

    pu.use("Contacts")
    for name, email in rows:
        pu.click("New Contact")
        pu.fill({"First name": name, "Email": email})
        pu.key("cmd+s")
    print(pu.read([0, 0, 400, 80]))

Every action waits for the window to settle, as `act` does. One that fails (or a batch the guard
stops) raises ActionError, so a script stops where it went wrong rather than carrying on blind.
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass, field
from typing import Any

from .client import Helper, HelperError
from .present import summarize, until_missed
from .settings import (act_params, capture_params, detail_param, element_number, element_numbers, outline_params,
                       session)

__all__ = ["Computer", "Result", "ActionError", "HelperError"]


class ActionError(Exception):
    """An action failed, or the batch stopped before the end. `.result` has the details."""

    def __init__(self, result: Result):
        super().__init__(result.text)
        self.result = result


@dataclass
class Result:
    raw: dict = field(repr=False)
    text: str = ""  # the status line(s) an agent would see

    @property
    def ok(self) -> bool:
        return not self.raw.get("errors") and not self.raw.get("stopped")

    @property
    def changed(self) -> bool:
        return self.raw.get("changed") is not False

    @property
    def clipboard(self) -> str | None:
        return self.raw.get("clipboard")

    def save_image(self, path: str | None = None) -> str | None:
        """Write the result's screenshot (if it has one) to `path`, or the CLI's shots folder."""
        from .cli import save_image

        if path is None:
            return save_image(self.raw)
        from .present import image_bytes

        img = image_bytes(self.raw)
        if not img:
            return None
        with open(path, "wb") as f:
            f.write(img[0])
        return path

    def __str__(self) -> str:
        return self.text


Aim = str | int | dict | None  # "Save" (what it shows), 14 or "#14" (its number), or {text, role, nth}


def _aim(a: dict, target: Aim, x: float | None = None, y: float | None = None) -> dict:
    if isinstance(target, bool):
        raise TypeError("target is text, an element number, or {text, role, nth}")
    target = element_number(target)
    if isinstance(target, int):
        a["element"] = target
    elif target is not None:
        a["target"] = target
    elif x is not None and y is not None:
        a["x"], a["y"] = x, y
    return a


def _ok(a: dict, confirm: bool) -> dict:
    if confirm:
        a["confirm"] = True
    return a


class Computer:
    """A connection to the helper, in one session (PUTER_USE_SESSION, else the CLI's "default"), on one
    window at a time. Not thread-safe; use one per thread."""

    def __init__(self, window: int | str | None = None, *, session_id: str | None = None,
                 screenshot: str = "never", guard: bool = True):
        self._loop = asyncio.new_event_loop()
        # A script reads each reply as it comes (a Ctrl-C mid-call hangs up, which the helper sees), so a
        # reply written counts as delivered: nothing to report afterwards.
        self._helper = Helper(session_id or session("default"), reports=False)
        self.window = window
        self.screenshot_mode = screenshot  # what act returns: "never" (scripts rarely look), "auto", "always"
        self.guard = guard

    # -- plumbing

    def _call(self, cmd: str, **params) -> dict:
        task = self._loop.create_task(self._helper.call(cmd, **params))
        try:
            return self._loop.run_until_complete(task)
        except KeyboardInterrupt:
            # Ctrl-C stops the loop but not the call: cancel it (closing the connection, which stops the
            # helper's batch), or it would carry on, still holding the connection, at the next call.
            task.cancel()
            try:
                self._loop.run_until_complete(task)
            except BaseException:
                pass
            self._helper.drop()
            raise

    def act(self, actions: list[dict] | dict, *, check: bool = True, screenshot: str | None = None,
            text: bool | str = False, save_as: str | dict | None = None, crop_changes: bool | None = None,
            detail: str | None = None) -> Result:
        """Run actions (act's JSON form) on the current window. Raises ActionError if one fails.
        crop_changes=True: when little changed, the image shows only that part; detail="low": a sparser image
        that keeps text readable. Left out, each goes by PUTER_USE_CROP_CHANGES / PUTER_USE_DETAIL."""
        if isinstance(actions, dict):
            actions = [actions]
        raw = self._call("act", window=self.window, actions=[element_numbers(a) for a in actions], save_as=save_as,
                         **outline_params(text),
                         **act_params(screenshot or self.screenshot_mode, None, self.guard, crop_changes, detail),
                         **capture_params())
        if w := raw.get("window", {}).get("id"):
            self.window = w  # it may have moved to a window the actions opened
        res = Result(raw, summarize(raw))
        if check and not res.ok:
            raise ActionError(res)
        return res

    def close(self) -> None:
        self._loop.run_until_complete(self._helper.close())
        self._loop.close()

    def __enter__(self) -> Computer:
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # -- looking

    def windows(self, app: str | None = None, launch: bool = False) -> list[dict]:
        """[{id, app, title, frame, on_screen}, …]"""
        return self._call("windows", app=app, launch=launch or None,
                          window_size=capture_params()["window_size"]).get("windows", [])

    def use(self, window: int | str) -> Computer:
        """Work on this window (an id, or an app name: its front window) from now on."""
        self.window = window
        return self

    def screenshot(self, *, text: bool | str = False, marks: bool = False, region: list[int] | None = None,
                   detail: str | None = None) -> Result:
        """detail="low": a sparser image that keeps text readable (a screenshot is at the usual detail otherwise)."""
        raw = self._call("screenshot", window=self.window, region=region, **outline_params(text, marks),
                         **capture_params(), **detail_param(detail))
        self.window = raw.get("window", {}).get("id", self.window)
        return Result(raw, summarize(raw))

    def outline(self, interactive: bool = False) -> str:
        """The window's accessibility outline: `#12 button "Save"`, plain text unnumbered, links in it as
        `[label](#12)`."""
        raw = self._call("screenshot", window=self.window, image=False,
                         **outline_params("interactive" if interactive else True), **capture_params())
        return raw.get("text", "")

    def read(self, what: list[int] | Aim | bool = True, *, offset: int = 0, limit: int | None = None,
             query: str | None = None) -> str:
        """With a box [x0, y0, x1, y1] of the last full screenshot: the text in it (or read off the screen).
        Otherwise the whole text of a text area or field, scrolled-out parts too: what is its number, what
        it shows ("Notes" or {text, role, nth}), or True (the focused one, else the window's only text
        area). A web page (True in a browser, unless a text area has the focus) comes whole as Markdown,
        its links and controls numbered as `[label](#12)` for click(12). From offset (below 0: that many characters from the end), limit characters (default: all of
        it, fetched 50000 at a time). With query: where that text is in it instead (case-insensitive), a
        line per match, `@offset: …the text around it…`, from offset on; read(what, offset=…) reads there."""
        if isinstance(what, list):
            if query is not None:
                raise TypeError("query searches an element's whole text, not a box's")
            return self._call("screenshot", window=self.window, region=what, image=False,
                              **capture_params()).get("text", "")
        if what is False or what is None:
            raise TypeError("read takes a box [x0, y0, x1, y1], an element's number, what it shows, or True")
        what = element_number(what)
        if query is not None:
            return self._call("screenshot", window=self.window, read=what, offset=offset, limit=limit,
                              query=query).get("read", "")
        parts, pos = [], offset
        while limit is None or pos < offset + limit:
            want = 50000 if limit is None else min(50000, offset + limit - pos)
            raw = self._call("screenshot", window=self.window, read=what, offset=pos, limit=want)
            parts.append(raw.get("read", ""))
            start, end, total = raw.get("read_range", [pos, pos, 0])
            if pos == offset:  # a negative offset came to `start`, counted from the beginning: go on from there
                offset = pos = start
            if end <= pos or end >= total:
                break
            pos = end
        return "".join(parts)

    _FOUND = re.compile(r'^\[(\d+)\] (\S+) "(.*)"(?: at \((-?\d+),(-?\d+)\))?')

    @classmethod
    def _found(cls, line: str) -> dict | None:
        """The element on one of find's lines, `[n] role "label" at (x,y)` (no place: off screen)."""
        if not (m := cls._FOUND.match(line)):
            return None
        return {"element": int(m[1]), "role": m[2], "label": m[3],
                "x": int(m[4]) if m[4] else None, "y": int(m[5]) if m[5] else None}

    def find(self, query: str | list[str] = "", role: str | None = None) -> list[dict]:
        """Elements showing `query`: [{element, role, label, x, y}, …] (x, y in screenshot pixels; None for
        one scrolled out of view). With role and no query: the elements of that role. A list of texts (at
        most 10) is looked up in one call, and each match also has the `query` it was found for."""
        many = not isinstance(query, str)
        texts = [q for i, q in enumerate(query) if q.strip() and q not in query[:i]] if many else [query]
        asked = {"queries": texts} if many else {"query": query or None}
        text = self._call("find", window=self.window, **asked, role=role, **capture_params()).get("text", "")
        out = []
        if len(texts) <= 1:  # one text (or a role alone): its matches, then those that only contain it
            if text.startswith("(nothing shows "):  # what's listed under it is only similar
                return out
            for line in text.splitlines():
                if found := self._found(line):
                    out.append({**found, "query": texts[0]} if many and texts else found)
            return out
        # Several: a part for each text in turn, begun by its header ('"Email":') or by one line saying it
        # wasn't found (or looked for).
        at = -1
        for line in text.splitlines():
            if found := self._found(line):
                if 0 <= at < len(texts):
                    out.append({**found, "query": texts[at]})
            elif line.startswith("(nothing shows ") or "wasn't looked for:" in line or (
                    line.endswith(":") and not line.startswith("partial matches")):
                at += 1
        return out

    def exists(self, query: str | list[str] = "", role: str | None = None) -> bool:
        return bool(self.find(query, role))

    def menus(self, query: str | None = None) -> str:
        return self._call("menus", window=self.window, query=query).get("text", "")

    def clipboard(self, text: str | None = None, *, offset: int = 0, limit: int | None = None) -> str | None:
        """The clipboard's text: `limit` characters (default 10000, at most 50000) from `offset`. When
        there's more, read on with offset; act({"type": "clipboard"}) also gives the note saying how much
        there is. Given text, put it there instead."""
        if text is not None:
            return self.act({"type": "clipboard", "text": text}).clipboard
        res = self.act({"type": "clipboard", **({"offset": offset} if offset else {}),
                        **({"limit": limit} if limit is not None else {})})
        return res.clipboard

    # -- acting (each is one act call; batch with act([...]) when speed matters)

    # confirm=True on any of these: the user has OK'd the press (Delete, Send, Pay, … raise ActionError
    # asking for that otherwise).

    def click(self, target: Aim = None, *, x: float | None = None, y: float | None = None, button: str = "left",
              count: int = 1, keys: list[str] | None = None, item: str | None = None, confirm: bool = False) -> Result:
        """item: choose this in the menu the click opens (a pop-up, or a context menu with
        button="right"), e.g. "Font > Bold"."""
        kind = {1: "click", 2: "double_click", 3: "triple_click"}[count]
        a = _aim({"type": kind}, target, x, y)
        if button != "left":
            a["button"] = button
        if keys:
            a["keys"] = keys
        if item:
            a["item"] = item
        return self.act(_ok(a, confirm))

    def type(self, text: str, into: Aim = None, *, clear: bool = False, submit: bool = False,
             confirm: bool = False) -> Result:
        a = _aim({"type": "type", "text": text}, into)
        if clear:
            a["clear"] = True
        if submit:
            a["submit"] = True
        return self.act(_ok(a, confirm))

    def key(self, keys: str | list[str], repeat: int = 1, *, confirm: bool = False) -> Result:
        a: dict[str, Any] = {"type": "keypress", "keys": keys}
        if repeat > 1:
            a["repeat"] = repeat
        return self.act(_ok(a, confirm))

    def menu(self, item: str, *, confirm: bool = False) -> Result:
        return self.act(_ok({"type": "menu", "item": item}, confirm))

    def select(self, target: Aim, option: str, *, confirm: bool = False) -> Result:
        return self.act(_ok(_aim({"type": "select", "option": option}, target), confirm))

    def fill(self, fields: dict[str, str | bool | int | float] | list[dict], submit: bool | str | int = False, *,
             confirm: bool = False) -> Result:
        """fields: {"Name": "Ada", "Size": "L", "Subscribe": True}, each key the label of a field, pop-up or
        checkbox: text is typed into a field or picks a pop-up's option, True/False ticks or unticks (give
        phone numbers and IDs as strings). Every key is looked up before anything is filled, and the fields
        are filled from the top of the form down. Or act's own list form ([{target, text|option|checked},
        …]), which also takes element numbers and `clear`. submit: True presses Return, or the button's text
        or number."""
        a: dict[str, Any] = {"type": "fill", "fields": dict(fields) if isinstance(fields, dict) else fields}
        if submit:
            a["submit"] = submit
        return self.act(_ok(a, confirm))

    def scroll(self, dy: int = 0, dx: int = 0, at: Aim = None, *, until: str | dict | None = None,
               max_scrolls: int | None = None) -> Result:
        """dy, dx: pixels, positive = down/right; at least one of them (a scroll of 0 px is refused).
        until: the text to scroll to ("Total", or {"text": …, "role": …}) instead: it scrolls a screenful at a
        time (or dy/dx at a time) until an element showing it is in view, at most max_scrolls times (default
        10, at most 15), and the result's note names what it found, numbered for element. Not found (the
        end reached, or max_scrolls used up), it raises ActionError."""
        a: dict[str, Any] = {"type": "scroll"}
        if until is None:
            if max_scrolls is not None:
                raise TypeError("max_scrolls goes with until")
            if not dy and not dx:
                raise ValueError("scroll needs dy and/or dx (pixels, positive = down/right), or until")
            a.update(scroll_y=dy, scroll_x=dx)
        else:
            a["until"] = until
            a.update({k: v for k, v in (("scroll_y", dy), ("scroll_x", dx)) if v})  # (none: a screenful)
            if max_scrolls is not None:
                a["max_scrolls"] = max_scrolls
        res = self.act(_aim(a, at))
        if until is not None and until_missed(res.raw):  # (alone in its batch, the helper only notes it)
            raise ActionError(res)
        return res

    def wait_for(self, text: str | None = None, *, gone: bool = False, role: str | None = None, change: bool = False,
                 timeout_ms: int = 5000) -> Result:
        """Until an element showing text appears (gone=True: goes). change=True instead: until the window looks
        different from when this act began, then settles; a note if not. To catch a change the action before
        starts, batch both: act([{"type": "click", "target": "Search"}, {"type": "wait_for", "change": True}])."""
        a: dict[str, Any] = {"type": "wait_for", "timeout_ms": timeout_ms}
        if text is not None:
            a["text"] = text
        if change:
            a["change"] = True
        if gone:
            a["gone"] = True
        if role:
            a["role"] = role
        return self.act(a)

    def navigate(self, url: str, new_window: bool | None = None, *, timeout_ms: int | None = None) -> Result:
        """timeout_ms: how long to wait for the page to load (default 10000, at most 30000); a note says if
        it was still loading."""
        a: dict[str, Any] = {"type": "navigate", "url": url}
        if new_window is not None:
            a["new_window"] = new_window
        if timeout_ms is not None:
            a["timeout_ms"] = timeout_ms
        return self.act(a)

    def open(self, target: str | None = None, app: str | None = None) -> Result:
        a: dict[str, Any] = {"type": "open"}
        if target:
            a["url" if "://" in target or target.startswith("mailto:") else "path"] = target
        if app:
            a["app"] = app
        return self.act(a)

    def macro(self, name: str, **vars: str) -> Result:
        """To OK the presses a replay makes: act({"type": "macro", "name": name, "confirm": True})."""
        return self.act({"type": "macro", "name": name, **({"vars": vars} if vars else {})})

    def release(self) -> None:
        """Hide this session's cursor and let go of the apps it held."""
        self._call("release", autostart=False)
