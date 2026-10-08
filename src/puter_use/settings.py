"""Capture defaults, overridable with environment variables (e.g. in an MCP server config)."""

from __future__ import annotations

import os


def capture_params() -> dict:
    """Sent to the helper. It captures losslessly at the final pixel size; `encoding()` compresses."""
    env = os.environ.get
    params: dict = {
        # Output pixels per screen point. 0.75 keeps 9-11 pt text legible on 1x and Retina displays alike.
        "scale": float(env("PUTER_USE_SCALE", "0.75")),
        "zoom_scale": float(env("PUTER_USE_ZOOM_SCALE", "2")),
        # Hard cap on image tokens, ceil(w/tile) * ceil(h/tile); 28 px tiles for Claude, 32 for OpenAI.
        "max_tokens": int(env("PUTER_USE_MAX_TOKENS", "1000")),
        "tile": int(env("PUTER_USE_TILE", "28")),
        "format": "png",
        # Windows the agent opens (cmd+n, launch) are left as the app sized them; "1280x860" etc. shrinks
        # them to fit that many points, which keeps screenshots sharp within the token cap.
        "window_size": env("PUTER_USE_WINDOW_SIZE", "off"),
        # The agent's pointer moves like a hand and the app receives that same path. Cursor: drawn or not;
        # speed 1 = human pace, 2 = twice as fast, 0 = jump.
        "cursor": env("PUTER_USE_CURSOR", "1") != "0",
        "cursor_speed": float(env("PUTER_USE_CURSOR_SPEED", "1")),
        # Typing pace of a fast human typist, with a human rhythm; 0 = as fast as possible.
        "typing_wpm": float(env("PUTER_USE_TYPING_WPM", "140")),
        # Text longer than this (per line, in characters) is pasted instead, as people do; 0 = always type.
        "paste_over": int(env("PUTER_USE_PASTE_OVER", "100")),
        # The first look at an app adds a few lines about it: its scripting support, its shortcuts, quirks.
        "app_cards": env("PUTER_USE_APP_CARDS", "1") != "0",
        # Longest accessibility outline sent (characters); longer ones are cut with a note.
        "max_chars": int(env("PUTER_USE_OUTLINE_CHARS", "8000")),
    }
    if trace := env("PUTER_USE_TRACE"):  # JSON-lines log of every event sent (scripts/check_motion.py)
        params["trace"] = trace
    for key in ("max_width", "max_height"):  # optional pixel caps on top of scale/max_tokens
        if v := env(f"PUTER_USE_{key.upper()}"):
            params[key] = int(v)
    return params


def session(default: str) -> str:
    """Whose turn this is: requests of one session share a current window, a pointer and what was last
    seen; sessions side by side get their own (and different pointer colours)."""
    return os.environ.get("PUTER_USE_SESSION") or default


def outline_params(text: bool | str = False, marks: bool = False) -> dict:
    """text: False, True / "all" (every element), or "interactive" (only what can be acted on).
    marks: number the interactive elements on the image, the same numbers as `element`."""
    return {"text": bool(text) or None, "interactive": text == "interactive" or None, "marks": marks or None}


def act_params(screenshot: str = "auto", settle_ms: int | None = None, guard: bool = True) -> dict:
    """How act observes the window afterwards: an image only on change ("auto"), "always", or "never".
    guard: stop before a pointer action aimed by coordinates once something opened over the window."""
    return {"screenshot": screenshot != "never", "always_image": screenshot == "always", "settle_ms": settle_ms,
            "guard": guard}


def encoding() -> dict:
    env = os.environ.get
    return {
        "fmt": env("PUTER_USE_FORMAT", "auto"),
        "quality": float(env("PUTER_USE_QUALITY", "0.8")),
        "max_bytes": int(env("PUTER_USE_MAX_BYTES", "72000")),
    }
