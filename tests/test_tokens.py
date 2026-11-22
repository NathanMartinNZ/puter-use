import asyncio
import base64
import io
import json

import pytest
from PIL import Image as PILImage
from PIL import features

from puter_use import tokens


def _encoded(fmt, size, **opts):
    buf = io.BytesIO()
    PILImage.new("RGB", size, "white").save(buf, fmt, **opts)
    return buf.getvalue()


# -- what an image costs, by vendor


@pytest.mark.parametrize("size, expected", [
    ((1064, 665), {"claude": 912, "gpt_4o": 1105, "gpt_5": 910, "gpt_5_2": 857, "gemini_2": 1548, "gemini_3": 1120}),
    ((1008, 637), {"claude": 828, "gpt_4o": 765, "gpt_5": 630, "gpt_5_2": 768, "gemini_2": 1548, "gemini_3": 1120}),
    ((294, 168), {"claude": 66, "gpt_4o": 255, "gpt_5": 210, "gpt_5_2": 72, "gemini_2": 258, "gemini_3": 1120}),
])
def test_image_tokens_by_vendor(size, expected):
    assert tokens.image_tokens(*size) == expected


def test_openai_tiles_are_counted_once_the_image_is_brought_down():
    assert tokens.openai_tiles(1024, 1024) == 4  # short side 1024 -> 768: 2x2
    assert tokens.openai_tiles(2048, 4096) == 6  # fitted to 1024x2048, then 768x1536: 2x3
    assert tokens.openai_tiles(300, 200) == 1  # never enlarged
    assert tokens.image_tokens(1024, 1024)["gpt_4o"] == 765
    assert tokens.image_tokens(2048, 4096)["gpt_4o"] == 1105


def test_gemini_2_cuts_a_larger_image_into_crops():
    assert tokens.gemini2_tokens(384, 384) == 258
    assert tokens.gemini2_tokens(768, 768) == 258 * 4  # crops of 512: 2x2


# -- reading an image's size from its header


def test_image_size_reads_png_and_jpeg_headers():
    from puter_use.imaging import encode

    raw = _encoded("PNG", (1064, 665))
    assert tokens.image_size(raw) == ("png", 1064, 665)
    palette, _ = encode(raw, fmt="png")  # as the agent gets it
    assert tokens.image_size(palette) == ("png", 1064, 665)
    jpeg, _ = encode(raw, fmt="jpeg")
    assert tokens.image_size(jpeg) == ("jpeg", 1064, 665)
    assert tokens.image_size(_encoded("JPEG", (1008, 637), quality=50)) == ("jpeg", 1008, 637)
    assert tokens.image_size(b"") is None
    assert tokens.image_size(b"not an image at all") is None
    assert tokens.image_size(raw[:20]) is None  # cut short


@pytest.mark.skipif(not features.check("webp"), reason="Pillow built without WebP")
def test_image_size_reads_webp_headers():
    assert tokens.image_size(_encoded("WEBP", (294, 168), quality=80)) == ("webp", 294, 168)
    assert tokens.image_size(_encoded("WEBP", (294, 168), lossless=True)) == ("webp", 294, 168)


# -- the records


def test_a_call_record_splits_the_text_and_prices_each_image():
    from mcp.server.mcpserver import Image

    png = _encoded("PNG", (294, 168))
    card = "shortcuts: Toggle Thing cmd+option+t"
    reply = {"window": {"id": 7, "app": "Probe"}, "notes": ["typed into Name"], "card": card,
             "text": '[1] button "OK"'}
    head = "Probe #7 · 294x168"
    text = f'{head}\nnote: typed into Name\nabout this app: {card}\n[1] button "OK"'
    rec = tokens.call_record("act", {"actions": [{"type": "click", "target": "OK"}]},
                             [Image(data=png, format="png"), text], reply=reply, ms=12.4)
    assert (rec["event"], rec["tool"], rec["outcome"], rec["ms"]) == ("call", "act", "ok", 12)
    assert rec["args_bytes"] == len('{"actions":[{"type":"click","target":"OK"}]}')
    assert rec["text_bytes"] == len(text.encode())
    assert rec["split"] == {"status": len(head.encode()) + 3, "notes": len("note: typed into Name"),
                            "errors": 0, "card": len(f"about this app: {card}"),
                            "outline": len('[1] button "OK"'), "read": 0}
    assert sum(rec["split"].values()) == rec["text_bytes"]
    assert rec["images"] == [{"bytes": len(png), "format": "png", "w": 294, "h": 168,
                              "tokens": tokens.image_tokens(294, 168)}]


def test_the_text_an_act_read_counts_as_read():
    from puter_use.present import summarize

    reply = {"window": {"id": 7, "app": "Probe"}, "done": 2, "total": 2, "clipboard": "copied",
             "reads": [{"read": "line one\nline two", "read_of": '[12] textarea "Notes"', "read_range": [0, 17, 17]},
                       {"read": "Total: $41.00", "read_of": "region (10,20)-(300,60)"}]}
    text = summarize(reply)
    split = tokens.text_split(reply, len(text.encode()))
    assert split["read"] == len("copied") + len("line one\nline two") + len("Total: $41.00")
    assert sum(split.values()) == len(text.encode())  # the labels count as status
    assert split["status"] == len(text.encode()) - split["read"]


def test_where_the_agent_is_counts_as_status():
    """url, focus, selected and scroll are part of the status line, not text read."""
    from puter_use.present import summarize

    reply = {"window": {"id": 7, "app": "Firefox"}, "url": "https://example.com/a", "focus": 'field "Search"',
             "selected": '"cats" (4 chars)', "scroll": "45% down", "notes": ["typed into Search"]}
    text = summarize(reply)
    head = text.split("\n")[0]
    assert "selected: " in head and "scroll: 45% down" in head
    split = tokens.text_split(reply, len(text.encode()))
    assert split["status"] == len(head.encode()) + 1  # the status line and its line break
    assert split["notes"] == len("note: typed into Search") and split["read"] == split["outline"] == 0


def test_error_results_failed_calls_and_cancelled_ones():
    from mcp.types import CallToolResult, ImageContent, TextContent

    png = _encoded("PNG", (40, 30))
    res = CallToolResult(is_error=True, content=[
        ImageContent(type="image", data=base64.b64encode(png).decode(), mime_type="image/png"),
        TextContent(type="text", text="App #7\nerror: nope")])
    rec = tokens.call_record("act", {}, res, reply={"window": {"id": 7, "app": "App"}, "errors": ["nope"]})
    assert rec["outcome"] == "error" and rec["text_bytes"] == len("App #7\nerror: nope")
    assert rec["split"]["errors"] == len("error: nope") and rec["images"][0]["w"] == 40

    failed = tokens.call_record("find", {"query": "x"}, error=RuntimeError("the helper isn't running"))
    assert failed["outcome"] == "error" and failed["text_bytes"] == len("the helper isn't running")
    assert failed["split"] == {"errors": failed["text_bytes"]} and failed["images"] == []

    gone = tokens.call_record("act", {}, ["x"], cancelled=True)
    assert gone["outcome"] == "cancelled" and gone["text_bytes"] == 0 and "split" not in gone


def test_call_arguments_leave_out_defaults_and_the_context():
    from puter_use.mcp_server import Action, Target, act, screenshot

    args = tokens.call_arguments(act, ([Action(type="click", target="OK")],),
                                 {"window": "Probe", "text": False, "guard": True, "ctx": object()})
    assert args == {"actions": [Action(type="click", target="OK")], "window": "Probe"}
    assert tokens.json_bytes(args) == len('{"actions":[{"type":"click","target":"OK"}],"window":"Probe"}')
    shot = tokens.call_arguments(screenshot, (), {"window": 3, "read": Target(text="Notes"), "image": True})
    assert tokens.json_bytes(shot) == len('{"window":3,"read":{"text":"Notes"}}')


def test_the_session_record_sizes_each_tool_as_advertised():
    from puter_use import mcp_server as m

    listed = asyncio.run(m.mcp.list_tools())
    rec = tokens.session_record(m.mcp.instructions, listed, session="s")
    assert rec["event"] == "session" and rec["session"] == "s"
    assert list(rec["tools_bytes"]) == [t.name for t in listed]
    act = next(t for t in listed if t.name == "act")
    assert rec["tools_bytes"]["act"] == len(json.dumps(
        {"name": "act", "description": act.description, "parameters": act.input_schema},
        separators=(",", ":"), ensure_ascii=False).encode())
    assert rec["instructions_bytes"] == len(m.mcp.instructions.encode())
    assert rec["static_bytes"] == rec["instructions_bytes"] + sum(rec["tools_bytes"].values())


# -- the log, through the MCP tools


def _fake_helper(monkeypatch, answer):
    """The MCP server's helper, answering every request with `answer` (a reply, or an error to raise)."""
    from puter_use import mcp_server as m
    from puter_use.client import Helper

    h = Helper("test-session")

    async def call(cmd, **params):
        if isinstance(answer, Exception):
            raise answer
        return dict(answer)

    monkeypatch.setattr(h, "call", call)
    monkeypatch.setattr(m, "helper", h)
    return m


def _lines(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def test_tool_calls_are_logged_without_changing_what_they_return(monkeypatch, tmp_path):
    m = _fake_helper(monkeypatch, {"window": {"id": 7, "app": "Probe"}, "text": '[3] button "Save" at (10,20)',
                                   "notes": ["one more off screen"]})
    monkeypatch.delenv("PUTER_USE_TOKEN_LOG", raising=False)
    plain = asyncio.run(m.find("Save", window="Probe"))
    log = tmp_path / "tokens.jsonl"
    monkeypatch.setenv("PUTER_USE_TOKEN_LOG", str(log))
    assert asyncio.run(m.find("Save", window="Probe")) == plain
    asyncio.run(m.find("Save", window="Probe"))
    session, *calls = _lines(log)
    assert session["event"] == "session" and session["session"] == "test-session"
    assert len(session["tools_bytes"]) == 6 and session["pid"] and session["ts"]
    assert [c["event"] for c in calls] == ["call", "call"]  # the session line comes once
    call = calls[0]
    assert call["tool"] == "find" and call["outcome"] == "ok"
    assert call["args_bytes"] == len('{"query":"Save","window":"Probe"}')
    assert call["text_bytes"] == len(plain.encode())
    assert call["split"]["outline"] == len('[3] button "Save" at (10,20)')
    assert call["split"]["notes"] == len("note: one more off screen") and call["images"] == []


def test_an_act_call_logs_its_image_size_and_tokens(monkeypatch, tmp_path):
    png = _encoded("PNG", (294, 168))
    m = _fake_helper(monkeypatch, {"window": {"id": 7, "app": "Probe"}, "done": 1, "total": 1, "changed": True,
                                   "image": base64.b64encode(png).decode(), "mime": "image/png", "width": 294,
                                   "height": 168, "zoom": False})
    log = tmp_path / "tokens.jsonl"
    monkeypatch.setenv("PUTER_USE_TOKEN_LOG", str(log))
    out = asyncio.run(m.act([m.Action(type="click", target="OK")], window="Probe"))
    call = _lines(log)[-1]
    assert call["tool"] == "act" and call["outcome"] == "ok" and call["text_bytes"] == len(out[1].encode())
    [img] = call["images"]
    assert (img["format"], img["w"], img["h"], img["bytes"]) == ("png", 294, 168, len(out[0].data))
    assert img["tokens"] == tokens.image_tokens(294, 168)


def test_a_failing_call_is_logged_and_still_fails(monkeypatch, tmp_path):
    from mcp.server.mcpserver.exceptions import ToolError

    from puter_use.client import HelperError

    m = _fake_helper(monkeypatch, HelperError("the helper isn't running"))
    log = tmp_path / "tokens.jsonl"
    monkeypatch.setenv("PUTER_USE_TOKEN_LOG", str(log))
    with pytest.raises(ToolError, match="the helper isn't running"):
        asyncio.run(m.windows())
    call = _lines(log)[-1]
    assert call["tool"] == "windows" and call["outcome"] == "error"
    assert call["split"] == {"errors": len("the helper isn't running")}


def test_a_log_that_cannot_be_written_never_gets_in_the_way(monkeypatch, tmp_path):
    m = _fake_helper(monkeypatch, {"window": {"id": 7, "app": "Probe"}, "text": "File: New cmd+n"})
    monkeypatch.setenv("PUTER_USE_TOKEN_LOG", str(tmp_path))  # a folder: nothing can be added to it
    assert asyncio.run(m.menus(window="Probe")) == "Probe #7\nFile: New cmd+n"

    def broken(*args, **kwargs):
        raise RuntimeError("a bug in the log")

    monkeypatch.setenv("PUTER_USE_TOKEN_LOG", str(tmp_path / "tokens.jsonl"))
    monkeypatch.setattr(tokens, "session_record", broken)
    monkeypatch.setattr(tokens, "call_record", broken)
    assert asyncio.run(m.menus(window="Probe")) == "Probe #7\nFile: New cmd+n"
    assert not (tmp_path / "tokens.jsonl").exists()


def test_what_can_be_acted_on_in_a_crop_counts_as_outline():
    """A crop's `crop_outline` is outline text; its label and the crop's note are status."""
    from puter_use.present import summarize

    outline = '#4 button "Save"\n#5 link "Help"'
    reply = {"window": {"id": 7, "app": "Probe"}, "image": "", "width": 112, "height": 112,
             "crop": [0, 0, 150, 150], "crop_outline": outline, "detail": {"level": "low", "scale": 0.62}}
    text = summarize(reply)
    split = tokens.text_split(reply, len(text.encode()))
    assert split["outline"] == len(outline.encode()) and split["read"] == 0
    assert sum(split.values()) == len(text.encode())
    assert tokens.text_split({"text": "abc", "crop_outline": "de"}, 10) == {
        "status": 5, "notes": 0, "errors": 0, "card": 0, "outline": 5, "read": 0}
    assert tokens.text_split({"text": "abc"}, 10)["outline"] == 3  # as before
