"""Sizes for the token log (PUTER_USE_TOKEN_LOG): what each MCP tool call puts in an agent's context, and
what the tools cost before any call. Text is counted in bytes (tokens per byte differ by model and
tokenizer). Images are counted by their pixel size, priced with each vendor's published formula, since
that is all any of them bills an image for.

Everything here is pure except `append`, which never raises: the log must not get in a tool call's way."""

from __future__ import annotations

import base64
import inspect
import json
import os
import struct
import time
from typing import Any


def _ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def claude_tokens(w: int, h: int) -> int:
    """Claude: a token per 28x28 px patch."""
    return _ceil_div(w, 28) * _ceil_div(h, 28)


def openai_tiles(w: int, h: int) -> int:
    """The 512 px tiles OpenAI's tile-billed models (gpt-4o, gpt-4.1, gpt-5, gpt-5.1) count in high detail:
    the image is first fitted within 2048x2048, then its short side brought down to 768, never enlarged."""
    if (longest := max(w, h)) > 2048:
        w, h = w * 2048 // longest, h * 2048 // longest
    if (shortest := min(w, h)) > 768:
        w, h = w * 768 // shortest, h * 768 // shortest
    return _ceil_div(w, 512) * _ceil_div(h, 512)


def openai_patch_tokens(w: int, h: int) -> int:
    """OpenAI's patch-billed models (gpt-5.2 and later): 32x32 px patches, times 1.2."""
    return _ceil_div(_ceil_div(w, 32) * _ceil_div(h, 32) * 6, 5)


def gemini2_tokens(w: int, h: int) -> int:
    """Gemini 2.x: 258 for an image within 384x384. A larger one is cut into square crops whose side is
    two thirds of its short side, at 258 each."""
    if w <= 384 and h <= 384:
        return 258
    crop = max(1, min(w, h) * 2 // 3)
    return 258 * _ceil_div(w, crop) * _ceil_div(h, crop)


GEMINI3_TOKENS = 1120  # Gemini 3: the same for every image, at the default media_resolution


def image_tokens(w: int, h: int) -> dict[str, int]:
    """What a w x h image costs under each vendor's formula."""
    tiles = openai_tiles(w, h)
    return {"claude": claude_tokens(w, h), "gpt_4o": 85 + 170 * tiles, "gpt_5": 70 + 140 * tiles,
            "gpt_5_2": openai_patch_tokens(w, h), "gemini_2": gemini2_tokens(w, h), "gemini_3": GEMINI3_TOKENS}


def image_size(data: bytes) -> tuple[str, int, int] | None:
    """(format, width, height) from a PNG, JPEG or WebP header; None for anything else."""
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24 and data[12:16] == b"IHDR":
        w, h = struct.unpack(">II", data[16:24])
        return "png", w, h
    if data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 <= len(data):
            if data[i] != 0xFF:
                return None
            marker = data[i + 1]
            if marker == 0xFF:  # padding
                i += 1
            elif marker in (0x01, 0xD8) or 0xD0 <= marker <= 0xD7:  # markers without a length
                i += 2
            elif 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):  # a start of frame
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return "jpeg", w, h
            else:
                i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
        return None
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP" and len(data) >= 30:
        chunk = data[12:16]
        if chunk == b"VP8 ":
            w, h = struct.unpack("<HH", data[26:30])
            return "webp", w & 0x3FFF, h & 0x3FFF
        if chunk == b"VP8L":
            bits = int.from_bytes(data[21:25], "little")
            return "webp", (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        if chunk == b"VP8X":
            return "webp", int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
    return None


def image_record(data: bytes) -> dict:
    """An image's encoded size and, when its header can be read, its pixel size and tokens."""
    record: dict[str, Any] = {"bytes": len(data)}
    if size := image_size(data):
        fmt, w, h = size
        record.update(format=fmt, w=w, h=h, tokens=image_tokens(w, h))
    return record


def content(result: Any) -> tuple[list[str], list[bytes]]:
    """The texts and the images (encoded bytes) in what a tool returned: a string, a list of strings and
    images, or a CallToolResult."""
    items = getattr(result, "content", result)
    if not isinstance(items, (list, tuple)):
        items = [items]
    texts: list[str] = []
    images: list[bytes] = []
    for item in items:
        data = getattr(item, "data", None)
        if isinstance(item, str):
            texts.append(item)
        elif isinstance(data, bytes):  # the SDK's Image helper
            images.append(data)
        elif getattr(item, "type", None) == "image" and isinstance(data, str):  # ImageContent: base64
            images.append(base64.b64decode(data))
        elif getattr(item, "type", None) == "text":
            texts.append(item.text)
    return texts, images


def text_split(reply: dict, text_bytes: int) -> dict[str, int]:
    """Where a result's text went, in bytes, worked out from the helper reply it was made from: notes,
    errors, the line about the app (card), the outline or its diff (or the list find, menus or macros
    return, or what can be acted on in an image of only what changed, crop_outline), text read (read,
    clipboard, and each of an act's reads), and the rest as status: the status line (with where the agent
    is: url, focus, selected, scroll), headers, line breaks, a window list, a stop message."""

    def size(s: Any) -> int:
        return len(str(s).encode())

    parts = {
        "notes": sum(size(f"note: {n}") for n in reply.get("notes") or ()),
        "errors": sum(size(f"error: {e}") for e in reply.get("errors") or ()),
        "card": size(f"about this app: {reply['card']}") if reply.get("card") else 0,
        "outline": sum(size(reply[k]) for k in ("text", "crop_outline") if reply.get(k)),
        "read": sum(size(reply[k]) for k in ("read", "clipboard") if reply.get(k))
        + sum(size(r["read"]) for r in reply.get("reads") or () if isinstance(r, dict) and r.get("read")),
    }
    return {"status": max(0, text_bytes - sum(parts.values())), **parts}


def call_arguments(fn: Any, args: tuple, kwargs: dict) -> dict:
    """What a tool call was given, near enough to what the model sent: parameters left at their default
    and the request context (ctx) are left out. These are the parsed values, not the model's own JSON."""
    params = inspect.signature(fn).parameters
    try:
        given = inspect.signature(fn).bind_partial(*args, **kwargs).arguments
    except TypeError:
        given = dict(kwargs)
    return {k: v for k, v in given.items() if k != "ctx" and (k not in params or v != params[k].default)}


def _plain(value: Any) -> Any:
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json", exclude_none=True)
    if isinstance(value, dict):
        return {str(k): _plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    return value


def json_bytes(value: Any) -> int:
    """The size of value as compact JSON, Pydantic models without their unset (None) fields."""
    return len(json.dumps(_plain(value), separators=(",", ":"), ensure_ascii=False, default=str).encode())


def call_record(tool: str, args: dict, result: Any = None, reply: dict | None = None,
                error: BaseException | None = None, cancelled: bool = False, ms: float = 0) -> dict:
    """A tool call: its arguments' size, its result text's size (split by `text_split` when the helper's
    reply is known), and each image's size and tokens. A cancelled call delivered nothing; one that raised
    delivered only its error message."""
    if cancelled:
        texts, images = [], []
    elif error is not None:
        texts, images = [str(error)], []
    else:
        texts, images = content(result)
    text_bytes = sum(len(t.encode()) for t in texts)
    failed = error is not None or bool(getattr(result, "is_error", False))
    record: dict[str, Any] = {"event": "call", "tool": tool,
                              "outcome": "cancelled" if cancelled else "error" if failed else "ok",
                              "ms": round(ms), "args_bytes": json_bytes(args), "text_bytes": text_bytes}
    if not cancelled and error is not None:
        record["split"] = {"errors": text_bytes}
    elif not cancelled and isinstance(reply, dict):
        record["split"] = text_split(reply, text_bytes)
    record["images"] = [image_record(data) for data in images]
    return record


def tool_bytes(tool: Any) -> int:
    """A tool's size as its definition reaches a model: compact JSON of its name, description and input
    schema."""
    return len(json.dumps({"name": tool.name, "description": tool.description, "parameters": tool.input_schema},
                          separators=(",", ":"), ensure_ascii=False).encode())


def session_record(instructions: str, tools: list, session: str | None = None) -> dict:
    """What a server costs before any call: its instructions and each tool as advertised, in bytes."""
    sizes = {t.name: tool_bytes(t) for t in tools}
    ins = len(instructions.encode())
    return {"event": "session", "session": session, "instructions_bytes": ins, "tools_bytes": sizes,
            "static_bytes": ins + sum(sizes.values())}


def append(path: str, record: dict) -> None:
    """Add a record to the log as one line, with the time and this process's id (servers side by side
    can share a file). Never raises."""
    try:
        line = json.dumps({"ts": round(time.time(), 3), "pid": os.getpid(), **record}, separators=(",", ":"),
                          ensure_ascii=False)
        with open(os.path.expanduser(path), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
