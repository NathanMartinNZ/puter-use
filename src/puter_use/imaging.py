"""Shrink screenshot bytes. The helper already picked the pixel size, which is all the model is billed
for (Claude: ceil(w/28)*ceil(h/28) tokens); this only makes the payload small for transport limits
(Claude Code caps an MCP result at ~25k tokens, about 72 KB of image).

UI screenshots are mostly flat colour and anti-aliased text, so a 256-colour palette PNG is lossless to
the eye, keeps text edges crisp and is usually 5-20 KB. Photo- or video-heavy windows quantize badly
and compress poorly as PNG, so "auto" falls back to JPEG when the PNG would exceed the budget."""

from __future__ import annotations

import io

from PIL import Image

FORMATS = ("auto", "png", "jpeg", "webp")
MIME = {"png": "image/png", "jpeg": "image/jpeg", "webp": "image/webp"}


def _flatten(img: Image.Image) -> Image.Image:
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGB", img.size, (255, 255, 255))
        bg.paste(img, mask=img.getchannel("A"))
        return bg
    return img.convert("RGB")


def _save(img: Image.Image, fmt: str, **opts) -> bytes:
    buf = io.BytesIO()
    img.save(buf, fmt, **opts)
    return buf.getvalue()


def png8(img: Image.Image) -> bytes:
    pal = img.quantize(256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    return _save(pal, "PNG", optimize=True)


def _lossy(img: Image.Image, fmt: str, quality: int, max_bytes: int) -> bytes:
    opts = {"method": 4} if fmt == "WEBP" else {"subsampling": "4:4:4" if quality >= 80 else "4:2:0"}
    data = _save(img, fmt, quality=quality, **opts)
    while max_bytes and len(data) > max_bytes and quality > 30:
        quality -= 10
        if fmt == "JPEG":
            opts["subsampling"] = "4:2:0"
        data = _save(img, fmt, quality=quality, **opts)
    return data


def encode(raw: bytes, fmt: str = "auto", quality: float = 0.8, max_bytes: int = 72_000) -> tuple[bytes, str]:
    """Re-encode a lossless capture. Returns (bytes, mime)."""
    fmt = (fmt or "auto").lower().replace("jpg", "jpeg")
    if fmt not in FORMATS:
        raise ValueError(f"format must be one of {', '.join(FORMATS)}")
    img = Image.open(io.BytesIO(raw))
    img.load()
    img = _flatten(img)
    q = int(round(quality * 100 if quality <= 1 else quality))
    if fmt in ("auto", "png"):
        data = png8(img)
        if fmt == "png" or not max_bytes or len(data) <= max_bytes:
            return data, MIME["png"]
        fmt = "jpeg"
    return _lossy(img, fmt.upper(), q, max_bytes), MIME[fmt]
