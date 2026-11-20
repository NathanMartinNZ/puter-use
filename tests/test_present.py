import base64

from puter_use.cli import build_action, parser
from puter_use.present import image_bytes, summarize, window_list


def test_summary_unchanged_is_one_line():
    res = {"window": {"id": 7, "app": "TextEdit", "title": "Untitled"}, "changed": False, "done": 2, "total": 2,
           "focused": 'textarea ""'}
    assert summarize(res) == 'TextEdit #7 "Untitled" · no visible change · focus: textarea ""'


def test_summary_with_image_and_change_box():
    res = {"window": {"id": 7, "app": "Firefox", "title": "x" * 80}, "image": "", "width": 1280, "height": 800,
           "changed": True, "change_box": [10, 20, 300, 400], "change_fraction": 0.1}
    line = summarize(res)
    assert "1280x800" in line and "changed in (10,20)-(300,400)" in line and "…" in line


def test_summary_of_a_stop_before_anything_ran_has_no_change_claim():
    """A confirm stop before action 1 ran nothing: "no visible change" would read as a press that did nothing."""
    stop = "stopped before action 1 (click): pressing “Delete” may not be undoable; it was not run. Ask the user"
    res = {"window": {"id": 7, "app": "App", "title": "w"}, "image": "", "width": 574, "height": 420,
           "changed": False, "done": 0, "total": 1, "stopped": stop}
    assert summarize(res).splitlines() == ['App #7 "w" · 574x420 · ran 0/1 actions', stop]
    # Once something ran, an unchanged window is still said to be.
    assert "no visible change" in summarize({**res, "done": 1, "total": 2})


def test_summary_reports_errors_and_partial_runs():
    res = {"window": {"id": 1, "app": "A"}, "done": 1, "total": 3, "errors": ["action 2 (click): boom"]}
    assert summarize(res).splitlines() == ["A #1 · ran 1/3 actions", "error: action 2 (click): boom"]


def test_window_list_warns_on_missing_permissions():
    res = {"windows": [{"id": 1, "app": "Notes", "title": "N", "frame": [0, 0, 800, 600], "on_screen": True}],
           "permissions": {"accessibility": True, "screen_recording": False}}
    out = window_list(res)
    assert out.startswith("1 · Notes · 'N' · 800x600") and "screen_recording" in out


def test_image_bytes_roundtrip():
    res = {"image": base64.b64encode(b"jpegdata").decode(), "mime": "image/jpeg"}
    assert image_bytes(res) == (b"jpegdata", "image/jpeg")


def test_cli_builds_actions():
    p = parser()
    assert build_action(p.parse_args(["click", "10", "20", "--double"])) == {"type": "double_click", "x": 10.0, "y": 20.0}
    assert build_action(p.parse_args(["click", "-e", "4", "--right"])) == {"type": "click", "button": "right", "element": 4}
    assert build_action(p.parse_args(["key", "cmd+shift+t"])) == {"type": "keypress", "keys": "cmd+shift+t"}
    assert build_action(p.parse_args(["drag", "1", "2", "3", "4"]))["path"] == [[1, 2], [3, 4]]
    assert build_action(p.parse_args(["scroll", "5", "6", "--dy", "300"])) == {
        "type": "scroll", "scroll_y": 300, "scroll_x": 0, "x": 5.0, "y": 6.0}


def _png(img) -> bytes:
    import io

    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def test_ui_screenshots_become_palette_png():
    from PIL import Image, ImageDraw

    from puter_use.imaging import encode

    img = Image.new("RGBA", (600, 400), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, 599, 399), 12, fill=(250, 250, 250, 255))
    for y in range(20, 380, 18):
        d.text((20, y), "Save  Cancel  Search results: 1-20 of 3,482", fill=(30, 30, 30, 255))
    data, mime = encode(_png(img))
    assert mime == "image/png" and Image.open(__import__("io").BytesIO(data)).mode == "P"
    assert len(data) < len(_png(img))


def test_photo_like_screenshots_fall_back_to_jpeg_under_budget():
    import os

    from PIL import Image

    from puter_use.imaging import encode

    noise = Image.frombytes("RGB", (500, 400), os.urandom(500 * 400 * 3))
    data, mime = encode(_png(noise), max_bytes=60_000)
    assert mime == "image/jpeg" and len(data) <= 60_000
    assert encode(_png(noise), "webp")[1] == "image/webp"


def _ui_and_best():
    """A UI-like image and today's slowest, smallest palette PNG of it (optimize=True)."""
    from PIL import Image, ImageDraw

    from puter_use.imaging import _save

    img = Image.new("RGB", (600, 400), (250, 250, 250))
    d = ImageDraw.Draw(img)
    for y in range(10, 390, 14):
        d.text((10 + y % 30, y), "Save  Cancel  Search results: 1-20 of 3,482  " * 2, fill=(30, 30, 30))
    pal = img.quantize(256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    return img, _save(pal, "PNG", optimize=True)


def test_png8_fast_save_keeps_the_same_palette_pixels():
    import io

    from PIL import Image

    from puter_use.imaging import png8

    img, best = _ui_and_best()
    fast = png8(img)
    a, b = Image.open(io.BytesIO(fast)), Image.open(io.BytesIO(best))
    assert a.format == "PNG" and a.mode == "P"
    assert a.tobytes() == b.tobytes() and a.getpalette() == b.getpalette()
    assert len(best) < len(fast) < len(best) * 1.5


def test_png_just_over_budget_retries_the_smaller_save_before_jpeg():
    from puter_use.imaging import encode, png8

    img, best = _ui_and_best()
    budget = (len(png8(img)) + len(best)) // 2
    assert encode(_png(img), max_bytes=budget) == (best, "image/png")
    assert encode(_png(img), "png", max_bytes=budget) == (best, "image/png")


def test_png_far_over_budget_skips_the_slow_save(monkeypatch):
    import os

    from PIL import Image

    from puter_use import imaging

    calls = []
    real = imaging._save
    monkeypatch.setattr(imaging, "_save", lambda img, fmt, **o: calls.append((fmt, o)) or real(img, fmt, **o))
    noise = Image.frombytes("RGB", (500, 400), os.urandom(500 * 400 * 3))
    assert imaging.encode(_png(noise), max_bytes=60_000)[1] == "image/jpeg"
    assert not any(o.get("optimize") for _, o in calls)


def test_capture_params_have_no_fixed_pixel_box(monkeypatch):
    from puter_use.settings import capture_params

    monkeypatch.delenv("PUTER_USE_MAX_WIDTH", raising=False)
    p = capture_params()
    assert "max_width" not in p and p["format"] == "png" and p["scale"] == 0.75 and p["max_tokens"] == 1000
    monkeypatch.setenv("PUTER_USE_MAX_WIDTH", "800")
    assert capture_params()["max_width"] == 800


def test_shot_accepts_window_flag_or_positional():
    a = parser().parse_args(["shot", "-w", "Firefox", "--region", "1,2,3,4", "--no-image"])
    assert a.window == "Firefox" and a.no_image
    b = parser().parse_args(["shot", "9972"])
    assert (b.window or b.window_pos) == "9972"


def test_window_size_setting(monkeypatch):
    from puter_use.settings import capture_params

    monkeypatch.delenv("PUTER_USE_WINDOW_SIZE", raising=False)
    assert capture_params()["window_size"] == "1440x900"
    monkeypatch.setenv("PUTER_USE_WINDOW_SIZE", "1280x860")
    assert capture_params()["window_size"] == "1280x860"
    monkeypatch.setenv("PUTER_USE_WINDOW_SIZE", "off")
    assert capture_params()["window_size"] == "off"
