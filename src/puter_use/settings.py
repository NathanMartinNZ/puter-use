"""Capture defaults, overridable with environment variables (e.g. in an MCP server config)."""

from __future__ import annotations

import os
from pathlib import Path


def capture_params() -> dict:
    """Sent to the helper. It captures losslessly at the final pixel size; `encoding()` compresses."""
    env = os.environ.get
    params: dict = {
        # Output pixels per screen point. 0.75 keeps 9-11 pt text legible on 1x and Retina displays alike.
        "scale": float(env("PUTER_USE_SCALE", "0.75")),
        # The most px per point a `region` zoom gets, which small regions do; bigger ones taper toward
        # twice `scale`, to keep their token cost down.
        "zoom_scale": float(env("PUTER_USE_ZOOM_SCALE", "2")),
        # Hard cap on image tokens, ceil(w/tile) * ceil(h/tile); 28 px tiles for Claude, 32 for OpenAI.
        "max_tokens": int(env("PUTER_USE_MAX_TOKENS", "1000")),
        "tile": int(env("PUTER_USE_TILE", "28")),
        "format": "png",
        # Windows the agent opens (navigate, open, cmd+n) are shrunk (never enlarged) to fit this many
        # points: 1440x900 is captured at the full 0.75 px/pt within the token cap. Windows an app opens
        # or restores as it launches keep their size. "off" leaves them all as the app sized them.
        "window_size": env("PUTER_USE_WINDOW_SIZE", "1440x900"),
        # The agent's pointer moves like a hand and the app receives that same path. Cursor: drawn or not;
        # speed 1 = human pace, 2 = twice as fast, 0 = jump.
        "cursor": env("PUTER_USE_CURSOR", "1") != "0",
        "cursor_speed": float(env("PUTER_USE_CURSOR_SPEED", "1")),
        # Typing pace of a fast human typist, with a human rhythm; 0 = as fast as possible.
        "typing_wpm": float(env("PUTER_USE_TYPING_WPM", "280")),
        # Text longer than this (per line, in characters) is pasted instead, as people do; 0 = always type.
        "paste_over": int(env("PUTER_USE_PASTE_OVER", "80")),
        # The first look at an app adds a few lines about it: its scripting support, its shortcuts, quirks,
        # saved macros.
        "app_cards": env("PUTER_USE_APP_CARDS", "1") != "0",
        # Longest accessibility outline sent (characters); longer ones are cut with a note.
        "max_chars": int(env("PUTER_USE_OUTLINE_CHARS", "8000")),
        # Whether an app may be brought forward for a moment to redraw one of the agent's windows (see
        # `bring_forward`).
        "bring_forward": bring_forward(),
        # Whether puter-use may show a non-activating popup asking the user to switch focus when a window
        # conflict blocks keys or a covered window needs redrawing (see `focus_prompt`).
        "focus_prompt": focus_prompt(),
    }
    if trace := env("PUTER_USE_TRACE"):  # JSON-lines log of every event sent (scripts/check_motion.py)
        params["trace"] = trace
    if profile := browser_profile():  # navigate goes to the agent's own Firefox, on this profile
        params["browser_profile"] = profile
    for key in ("max_width", "max_height"):  # optional pixel caps on top of scale/max_tokens
        if v := env(f"PUTER_USE_{key.upper()}"):
            params[key] = int(v)
    return params


def browser_profile() -> str | None:
    """PUTER_USE_BROWSER_PROFILE=agent: a navigate with no window, or one aimed at Firefox by name, goes to the
    agent's own Firefox, a second instance on a puter-use profile started in the background, instead of the user's
    Firefox or the default browser. An absolute path (a leading `~` is expanded) instead: the same, on that profile
    folder (the helper uses only a new or empty one, or one it set up). "agent", the path, or None (anything else,
    or unset: off, the default)."""
    value = (os.environ.get("PUTER_USE_BROWSER_PROFILE") or "").strip()
    if value.lower() == "agent":
        return "agent"
    path = os.path.expanduser(value)
    return path if os.path.isabs(path) else None


def bring_forward() -> str:
    """PUTER_USE_BRING_FORWARD: "when-needed" (the default) or "never". When one of the agent's own windows
    has stopped drawing while covered (Firefox does that) and the user has left the keyboard and mouse alone
    for a few seconds, the helper brings its app forward for a moment, until the window draws again, then
    gives focus back to the app the user was in. "never" (or "off", "0", "false", "no"): it only says the window
    isn't being drawn. Anything else counts as the default."""
    value = (os.environ.get("PUTER_USE_BRING_FORWARD") or "").strip().lower()
    return "never" if value in ("never", "off", "0", "false", "no") else "when-needed"


def focus_prompt() -> str:
    """PUTER_USE_FOCUS_PROMPT: "when-needed" (the default) or "never". When keys, shortcuts, menu commands, or
    redrawing a covered window are blocked because the user is active in another window of the same app (or in
    the background on a non-agent window), the helper shows a non-activating macOS popup letting the user click
    Switch Window / Allow or Decline. "never" (or "off", "0", "false", "no"): never show the popup; fail with
    the usual message. Anything else counts as the default."""
    value = (os.environ.get("PUTER_USE_FOCUS_PROMPT") or "").strip().lower()
    return "never" if value in ("never", "off", "0", "false", "no") else "when-needed"


def read_params() -> dict:
    """Bring-forward / focus-prompt overrides for screenshot(read=...) only when disabled (omitted at default
    so read requests stay minimal and the helper applies its defaults)."""
    out: dict = {}
    if bring_forward() == "never":
        out["bring_forward"] = "never"
    if focus_prompt() == "never":
        out["focus_prompt"] = "never"
    return out


def session(default: str) -> str:
    """Whose turn this is: requests of one session share a current window, a pointer and what was last
    seen; sessions side by side get their own (and different pointer colours)."""
    return os.environ.get("PUTER_USE_SESSION") or default


def token_log() -> str | None:
    """A JSON-lines file the MCP server appends each tool call's size to (see tokens.py), and once what
    its instructions and tools cost before any call. Unset: nothing is logged."""
    return os.environ.get("PUTER_USE_TOKEN_LOG") or None


def outline_params(text: bool | str = False, marks: bool = False) -> dict:
    """text: False, True / "all" (every element), or "interactive" (only what can be acted on).
    marks: number the interactive elements on the image, the same numbers as `element`."""
    return {"text": bool(text) or None, "interactive": text == "interactive" or None, "marks": marks or None}


def element_number(v):
    """`v` as an element's number when it's one as an outline writes it, "#12" (exactly "#" and digits);
    anything else as it is (a label, a number)."""
    if isinstance(v, str) and len(v) > 1 and v[0] == "#" and v[1:].isascii() and v[1:].isdigit():
        return int(v[1:])
    return v


def element_numbers(action):
    """An action (act's JSON form) with "#12" as 12 where it takes an element's number: its `element`, and a
    fill's `submit` and each of its fields' `element`. Anything else as it is."""
    if not isinstance(action, dict):
        return action
    out = {k: element_number(v) if k in ("element", "submit") else v for k, v in action.items()}
    if isinstance(out.get("submit"), dict):
        out["submit"] = element_numbers(out["submit"])
    if isinstance(out.get("fields"), list):
        out["fields"] = [element_numbers(f) for f in out["fields"]]
    return out


def act_params(screenshot: str | None = None, settle_ms: int | None = None, guard: bool = True,
               crop_changes: bool | None = None, detail: str | None = None) -> dict:
    """How act observes the window afterwards: an image only on change ("auto"), "always", or "never".
    None leaves it to the helper (both sent as None, so neither goes): the way the agent last looked at
    the window decides, its outline's changes after a screenshot without an image, else as "auto".
    guard: stop before a pointer action aimed by coordinates once something opened over the window.
    With PUTER_USE_TRIM_BLANK=0, also `trim_blank: false` (see `trim_blank`). crop_changes, detail: the
    opt-in image options, each sent only when on (see `picture_params`)."""
    if screenshot is None:
        out = {"screenshot": None, "always_image": None, "settle_ms": settle_ms, "guard": guard}
    else:
        out = {"screenshot": screenshot != "never", "always_image": screenshot == "always", "settle_ms": settle_ms,
               "guard": guard}
    if not trim_blank():
        out["trim_blank"] = False
    out.update(picture_params(crop_changes, detail))
    return out


def picture_params(crop_changes: bool | None = None, detail: str | None = None) -> dict:
    """An act's opt-in image options, each sent only when on (the helper has both off unless asked):
    `crop_changes: true` (an image of only the part that changed, when that's small: `default_crop_changes`)
    and `detail: "low"` (`detail_param`). Left as None, each goes by its setting; given, it has the last
    word (crop_changes=False or detail="normal" turn off what the environment turned on)."""
    out: dict = {}
    if default_crop_changes() if crop_changes is None else crop_changes:
        out["crop_changes"] = True
    out.update(detail_param(default_detail() if detail is None else detail))
    return out


def detail_param(detail: str | None) -> dict:
    """`{"detail": "low"}` for low detail (any case), else nothing: a screenshot's or an act's image at as few
    pixels a point as keep the window's text about 10 px high (never below 0.5 px/pt, never sharper than
    usual). The reply says so, with its scale. A zoom keeps its own."""
    return {"detail": "low"} if isinstance(detail, str) and detail.strip().lower() == "low" else {}


def default_crop_changes() -> bool:
    """PUTER_USE_CROP_CHANGES=1: when only a small part of the window changed, an act's image may show just
    that part (the reply's `crop`), and its coordinates are that image's own pixels. A whole image still
    comes for a first look, every fifth image, a new, moved or resized window, a sheet or pop-up, an error,
    any stop and a press given confirm; a screenshot is always whole. Off by default."""
    return _on("PUTER_USE_CROP_CHANGES")


def default_detail() -> str | None:
    """PUTER_USE_DETAIL=low: act images at low detail (`detail_param`); a screenshot keeps its usual detail
    unless asked for low. Anything else: None (as usual)."""
    return "low" if (os.environ.get("PUTER_USE_DETAIL") or "").strip().lower() == "low" else None


def trim_blank() -> bool:
    """Whether an act's image may leave out the window's blank margins (the helper's default): blank sides
    of a page, with a scroll bar at the right edge kept, and a blank bottom, when that saves enough tokens.
    The agent's coordinates are the trimmed image's, mapped back to the window. A screenshot is never
    trimmed. PUTER_USE_TRIM_BLANK=0: act images show the whole window."""
    return os.environ.get("PUTER_USE_TRIM_BLANK", "1").strip() != "0"


def encoding() -> dict:
    env = os.environ.get
    return {
        "fmt": env("PUTER_USE_FORMAT", "auto"),
        "quality": float(env("PUTER_USE_QUALITY", "0.8")),
        "max_bytes": int(env("PUTER_USE_MAX_BYTES", "72000")),
    }


# Leaner MCP profiles, all off unless set. The first two shape what the server advertises, so it reads them
# once, as it starts: tools and instructions that changed mid-session would cost the client its prompt cache.


def _on(name: str) -> bool:
    return (os.environ.get(name) or "").strip().lower() in ("1", "true", "yes", "on")


def thin_schema() -> bool:
    """PUTER_USE_SCHEMA=thin: act's schema advertises of each action only its type and how it's aimed, and its
    description leaves the rarely needed actions to a resource. Calls are checked in full either way."""
    return (os.environ.get("PUTER_USE_SCHEMA") or "").strip().lower() == "thin"


def macros_enabled() -> bool:
    """PUTER_USE_MACROS=0: no macros tool, and act's schema and description leave macros out."""
    return os.environ.get("PUTER_USE_MACROS", "1").strip() != "0"


def image_meta() -> bool:
    """PUTER_USE_IMAGE_META=1: each image in a tool result says, in its `_meta`, which window it shows, its
    number among that window's and which earlier ones it supersedes, for a client that drops old ones."""
    return _on("PUTER_USE_IMAGE_META")


def image_delivery() -> str:
    """PUTER_USE_IMAGE_DELIVERY: "inline" (every image in its result) or "hybrid" (an act whose edit the
    helper checked by accessibility saves its image to a file and says where). Anything else: inline."""
    mode = (os.environ.get("PUTER_USE_IMAGE_DELIVERY") or "").strip().lower()
    return mode if mode == "hybrid" else "inline"


def omit_verified() -> bool:
    """PUTER_USE_OMIT_VERIFIED=1: an act whose edit the helper checked by accessibility comes without its image
    (hybrid delivery, when also set, saves it instead)."""
    return _on("PUTER_USE_OMIT_VERIFIED")


def verify_edits() -> bool:
    """Whether act asks the helper to say when it checked a batch's edit by accessibility (`verified`): only
    when an image would be kept out of the result for it."""
    return omit_verified() or image_delivery() == "hybrid"


def image_dir() -> Path:
    """Where hybrid delivery saves act images, a folder per session (not the CLI's shots folder, whose
    clean-up expects only files)."""
    return Path.home() / "Library/Caches/puter-use/mcp-shots"
