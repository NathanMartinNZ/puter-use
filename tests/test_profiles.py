"""The MCP server's leaner profiles: a thin act schema with its resource, no macros, image metadata, and
images of edits checked by accessibility kept out of results (saved to a file, or left out). Each is off
unless set, and off leaves everything exactly as it was."""

import asyncio
import base64
import copy
import importlib
import io
import json
import os
from pathlib import Path

import pytest

from puter_use.client import Helper

TOGGLES = ("PUTER_USE_SCHEMA", "PUTER_USE_MACROS", "PUTER_USE_IMAGE_META", "PUTER_USE_IMAGE_DELIVERY",
           "PUTER_USE_OMIT_VERIFIED", "PUTER_USE_CROP_CHANGES", "PUTER_USE_DETAIL")
URI = "puter-use://docs/advanced-actions"


@pytest.fixture
def server(monkeypatch):
    """`server(**env)`: the MCP server module loaded afresh with that environment (the schema and macros
    profiles are read as it loads), and loaded again with none of it afterwards, for the tests that follow.
    That last load defines every name in it anew, so attributes a test sets on it need no undoing."""
    from puter_use import mcp_server

    def load(**env):
        for name in TOGGLES:
            monkeypatch.delenv(name, raising=False)
        for name, value in env.items():
            monkeypatch.setenv(name, value)
        return importlib.reload(mcp_server)

    yield load
    for name in TOGGLES:
        monkeypatch.delenv(name, raising=False)
    importlib.reload(mcp_server)


def surface(m):
    """All a server shows a client before any call: its instructions, its tools as they go on the wire, and
    its resources."""
    from mcp.types import ListToolsResult

    tools = ListToolsResult(tools=asyncio.run(m.mcp.list_tools())).model_dump_json(by_alias=True,
                                                                                  exclude_unset=True)
    resources = [r.model_dump_json(by_alias=True, exclude_unset=True) for r in asyncio.run(m.mcp.list_resources())]
    return m.mcp.instructions, tools, resources


def tools_of(m):
    return {t.name: t for t in asyncio.run(m.mcp.list_tools())}


def _png(w=40, h=30):
    from PIL import Image as PILImage

    buf = io.BytesIO()
    PILImage.new("RGB", (w, h), "white").save(buf, "PNG")
    return buf.getvalue()


def shot(wid=7, **extra):
    """A helper reply with an image of window `wid`."""
    return {"window": {"id": wid, "app": "Probe", "title": "w"}, "image": base64.b64encode(_png()).decode(),
            "mime": "image/png", "width": 40, "height": 30, "zoom": False, "changed": True, **extra}


def edit(wid=7, **extra):
    """An act's reply after an edit the helper checked by accessibility (`extra` has the last word)."""
    return {**shot(wid), "done": 1, "total": 1, "verified": True, **extra}


def fake_helper(m, replies):
    """m's helper answers each request with the next of `replies`. The requests it got, as (cmd, params)."""
    got = []
    h = Helper("t")

    async def call(cmd, **params):
        got.append((cmd, params))
        return dict(replies.pop(0))

    h.call = call
    m.helper = h
    return got


def items(result):
    return result.content if hasattr(result, "content") else result


def has_image(result):
    from mcp.server.mcpserver import Image
    from mcp.types import ImageContent

    return any(isinstance(c, (Image, ImageContent)) for c in items(result))


TYPE_ADA = {"type": "type", "target": "Name", "text": "Ada"}


# -- off by default, and off is the default


def test_every_profile_left_off_is_the_default_byte_for_byte(server):
    default = surface(server())
    explicit_off = surface(server(PUTER_USE_SCHEMA="full", PUTER_USE_MACROS="1", PUTER_USE_IMAGE_META="0",
                                  PUTER_USE_IMAGE_DELIVERY="inline", PUTER_USE_OMIT_VERIFIED="0"))
    assert explicit_off == default
    # The image settings change results only, never what the server advertises.
    assert surface(server(PUTER_USE_IMAGE_META="1", PUTER_USE_IMAGE_DELIVERY="hybrid",
                          PUTER_USE_OMIT_VERIFIED="1")) == default
    assert surface(server(PUTER_USE_SCHEMA="something else", PUTER_USE_MACROS="")) == default


def test_by_default_the_instructions_and_act_are_as_written(server):
    from puter_use.client import cli_command

    m = server()
    assert m.mcp.instructions == m.INSTRUCTIONS.replace("{cli}", cli_command())
    assert m.instructions() is m.INSTRUCTIONS
    written = m.act.__wrapped__.__doc__
    assert m.act.__doc__ == written and tools_of(m)["act"].description == written
    assert m.act_texts(written) == (written, "") and m.ADVANCED_ACTIONS == ""
    assert list(tools_of(m)) == ["windows", "screenshot", "find", "menus", "macros", "act"]
    assert asyncio.run(m.mcp.list_resources()) == []


def test_a_profile_changes_only_act_and_leaves_the_schema_given_alone():
    from puter_use import mcp_server as m

    schemas = {name: t.input_schema for name, t in tools_of(m).items()}
    before = copy.deepcopy(schemas)
    for name, schema in schemas.items():
        assert m.profile_schema(name, schema) is schema  # the default profile: as it is
        if name != "act":
            assert m.profile_schema(name, schema, thin=True, macros=False) is schema
    assert m.profile_schema("act", schemas["act"], thin=True, macros=False) != schemas["act"]
    assert schemas == before  # (the server's own listing is cached: it must not change under it)


def test_the_profiles_are_read_from_the_environment(monkeypatch):
    from puter_use import settings

    for name in TOGGLES:
        monkeypatch.delenv(name, raising=False)
    assert not settings.thin_schema() and settings.macros_enabled() and not settings.image_meta()
    assert settings.image_delivery() == "inline" and not settings.omit_verified() and not settings.verify_edits()
    for value, thin in (("thin", True), (" Thin ", True), ("full", False), ("", False)):
        monkeypatch.setenv("PUTER_USE_SCHEMA", value)
        assert settings.thin_schema() is thin
    monkeypatch.setenv("PUTER_USE_MACROS", "0")
    assert not settings.macros_enabled()
    for value, on in (("1", True), ("true", True), ("0", False), ("", False), ("no", False)):
        monkeypatch.setenv("PUTER_USE_IMAGE_META", value)
        assert settings.image_meta() is on
    for value, mode in (("hybrid", "hybrid"), ("HYBRID", "hybrid"), ("inline", "inline"), ("files", "inline")):
        monkeypatch.setenv("PUTER_USE_IMAGE_DELIVERY", value)
        assert settings.image_delivery() == mode
    assert str(settings.image_dir()).endswith("Library/Caches/puter-use/mcp-shots")


# -- PUTER_USE_SCHEMA=thin


def test_a_thin_schema_advertises_only_an_actions_type_and_aim(server):
    default = server()
    full, instructions = tools_of(default), default.mcp.instructions
    m = server(PUTER_USE_SCHEMA="thin")  # (the same module, loaded again: what it had before is gone)
    thin = tools_of(m)
    assert list(thin) == list(full)
    act, whole = thin["act"].input_schema, full["act"].input_schema
    action = act["properties"]["actions"]["items"]
    assert list(action["properties"]) == ["type", "x", "y", "element", "target", "confirm"]
    assert action["required"] == ["type"] and action["type"] == "object" and action["additionalProperties"] is True
    assert action["properties"]["type"] == whole["properties"]["actions"]["items"]["properties"]["type"]
    assert {"hold_key", "perform", "macro"} <= set(action["properties"]["type"]["enum"])  # every name still listed
    assert action["properties"]["element"] == {"anyOf": [{"type": "integer"}, {"type": "string"}]}
    # act's other parameters, and the other tools, as by default.
    assert {k: v for k, v in act["properties"].items() if k != "actions"} == {
        k: v for k, v in whole["properties"].items() if k != "actions"}
    for name in ("windows", "screenshot", "find", "menus", "macros"):
        assert thin[name].input_schema == full[name].input_schema and thin[name].description == full[name].description
    assert m.mcp.instructions == instructions
    assert len(json.dumps(act, separators=(",", ":"))) < len(json.dumps(whole, separators=(",", ":"))) - 1000


def test_a_thin_schema_still_checks_calls_in_full(server):
    from mcp.server.mcpserver.exceptions import ToolError

    m = server(PUTER_USE_SCHEMA="thin")
    seen = []

    async def fake_consent(ctx, params):
        seen.append(params)
        return {"window": {"id": 1, "app": "X"}, "done": 1, "total": 1, "changed": False}

    m._run_with_consent = fake_consent
    m.helper = Helper("t")
    for actions in ([{"type": "explode"}], [{"type": "hold_key", "keys": "a", "ms": 20000}],
                    [{"type": "scroll", "scroll_y": "lots"}], [{"type": "wait", "ms": 40000}]):
        with pytest.raises(ToolError):
            asyncio.run(m.mcp.call_tool("act", {"actions": actions}))
    assert not seen
    rare = [{"type": "hold_key", "keys": "shift", "ms": 500}, {"type": "scroll", "scroll_y": 300},
            {"type": "perform", "target": "Disclosure", "name": "expand"}]
    out = asyncio.run(m.mcp.call_tool("act", {"actions": rare}))
    assert out.is_error is False and seen[0]["actions"] == rare


def test_a_thin_description_names_the_rare_actions_and_points_at_the_resource(server):
    m = server(PUTER_USE_SCHEMA="thin")
    desc, written = m.act.__doc__, m.act.__wrapped__.__doc__
    assert tools_of(m)["act"].description == desc and len(desc) < len(written) and len(desc) <= 4096
    for syntax in ("key_down/key_up {keys}", "hold_key {", "mouse_up {", "set_value {", "focus {element",
                   "perform {", "macro {", "activate {}", "save_as: name"):
        assert syntax not in desc, syntax
    [pointer] = [line for line in desc.splitlines() if URI in line]
    assert all(name in pointer for name in m.RARE_ACTIONS) and "save_as" in pointer
    assert "- wait {ms}; close_window {}" in desc.splitlines()
    # Every other line is the full description's, in its order.
    kept = [line for line in desc.splitlines() if line not in (pointer, "- wait {ms}; close_window {}")]
    rest = iter(written.splitlines())
    assert all(line in rest for line in kept)
    # The same every time: it's part of what the server advertises.
    assert m.act_texts(written, thin=True) == (desc, m.ADVANCED_ACTIONS)


def test_a_thin_schema_has_the_rare_actions_in_a_resource(server):
    m = server(PUTER_USE_SCHEMA="thin")
    [listed] = asyncio.run(m.mcp.list_resources())
    assert listed.uri == URI == m.ADVANCED_ACTIONS_URI and listed.name == "advanced-actions"
    assert listed.mime_type == "text/plain"
    [read] = asyncio.run(m.mcp.read_resource(URI))
    text = read.content
    assert text == m.ADVANCED_ACTIONS and read.mime_type == "text/plain"
    for syntax in ("key_down/key_up {keys}", "hold_key {keys, ms ≤ 10000}", "mouse_down", "mouse_up {x?,y?}",
                   "set_value {element|target, text}", "focus {element|target}", "perform {element|target, name}",
                   "macro {name, vars?}: replay a saved macro", "activate {}", "save_as", "on replay"):
        assert syntax in text, syntax
    # What left the description is what the resource says, word for word.
    desc = m.act.__doc__.splitlines()
    for line in m.act.__wrapped__.__doc__.splitlines():
        if line not in desc and not line.startswith(("- macro ", "save_as: ")):
            assert line in text.splitlines(), line


def test_a_thin_schema_without_macros_says_nothing_of_them(server):
    m = server(PUTER_USE_SCHEMA="thin", PUTER_USE_MACROS="0")
    desc, text = m.act.__doc__, m.ADVANCED_ACTIONS
    assert list(tools_of(m)) == ["windows", "screenshot", "find", "menus", "act"]
    for word in ("macro", "save_as"):
        assert word not in desc and word not in text and word not in m.mcp.instructions
    [pointer] = [line for line in desc.splitlines() if URI in line]
    assert "activate" in pointer and "hold_key" in pointer
    assert "- activate {}" in text.splitlines() and "set_value {element|target, text}" in text
    action = tools_of(m)["act"].input_schema["properties"]["actions"]["items"]["properties"]
    assert list(action) == ["type", "x", "y", "element", "target", "confirm"]
    assert "macro" not in action["type"]["enum"]
    [read] = asyncio.run(m.mcp.read_resource(URI))
    assert read.content == text


# -- PUTER_USE_MACROS=0


def test_without_macros_there_are_five_tools_and_no_save_as(server):
    from mcp.server.mcpserver.exceptions import ToolError

    full = tools_of(server(PUTER_USE_MACROS="1"))
    m = server(PUTER_USE_MACROS="0")
    tools = tools_of(m)
    assert list(tools) == ["windows", "screenshot", "find", "menus", "act"]
    act = tools["act"].input_schema
    assert "save_as" not in act["properties"]
    action = act["properties"]["actions"]["items"]
    assert "vars" not in action["properties"] and "macro" not in action["properties"]["type"]["enum"]
    assert "hold_key" in action["properties"]["type"]["enum"] and "fields" in action["properties"]
    for text in (tools["act"].description, m.mcp.instructions):
        assert "macro" not in text and "save_as" not in text
    assert "- wait {ms}; activate {}; close_window {}" in tools["act"].description.splitlines()
    hint = m.mcp.instructions.split("load all five at once: ")[1].split(".")[0]
    assert sorted(hint.split(", ")) == sorted(tools)
    # The rest as by default: the other tools, and the other lines of act's description.
    for name in ("windows", "screenshot", "find", "menus"):
        assert tools[name] == full[name]
    gone = [line for line in full["act"].description.splitlines() if line not in tools["act"].description.splitlines()]
    assert gone and all("macro" in line or "on replay" in line for line in gone)
    assert asyncio.run(m.mcp.list_resources()) == []
    with pytest.raises(ToolError):
        asyncio.run(m.mcp.call_tool("macros", {}))


def test_without_macros_the_instructions_lose_only_what_they_say_of_them():
    from puter_use import mcp_server as m

    off = m.instructions(macros=False)
    assert "macro" not in off and "save_as" not in off
    assert "load all five at once: windows, screenshot, find, menus, act. Loop:" in off
    head, _, about_macros = m.INSTRUCTIONS.partition("\nAdd save_as ")
    assert "macro" in about_macros and off.endswith("off limits to you.")
    assert off == head.replace("all six at once: windows, screenshot, find, menus, macros, act",
                               "all five at once: windows, screenshot, find, menus, act")


def test_without_macros_a_saved_macro_still_replays_by_name(server):
    m = server(PUTER_USE_MACROS="0")
    seen = []

    async def fake_consent(ctx, params):
        seen.append(params)
        return {"window": {"id": 1, "app": "X"}, "done": 1, "total": 1, "changed": False}

    m._run_with_consent = fake_consent
    m.helper = Helper("t")
    replay = [{"type": "macro", "name": "export", "vars": {"file": "a.pdf"}}]
    out = asyncio.run(m.mcp.call_tool("act", {"actions": replay}))
    assert out.is_error is False and seen[0]["actions"] == replay


# -- PUTER_USE_IMAGE_META=1


def test_images_carry_meta_numbering_them_per_window(server):
    from mcp.types import ImageContent

    m = server(PUTER_USE_IMAGE_META="1")
    fake_helper(m, [shot(7), shot(7, zoom=True), shot(9), shot(7, done=1, total=1), shot(7, zoom=True)])
    results = [asyncio.run(m.screenshot(window=7)), asyncio.run(m.screenshot(window=7, region=[0, 0, 20, 20])),
               asyncio.run(m.screenshot(window=9)),
               asyncio.run(m.act([m.Action(type="click", target="OK")], window=7)),
               asyncio.run(m.screenshot(window=7, region=[0, 0, 20, 20]))]
    images = [r[0] for r in results]
    assert all(isinstance(i, ImageContent) and i.mime_type == "image/png" for i in images)
    assert [i.meta for i in images] == [
        {"puter_use": {"window_id": 7, "seq": 1, "kind": "full", "supersedes_before_seq": 1}},
        {"puter_use": {"window_id": 7, "seq": 2, "kind": "zoom", "supersedes_before_seq": 1}},
        {"puter_use": {"window_id": 9, "seq": 1, "kind": "full", "supersedes_before_seq": 1}},
        {"puter_use": {"window_id": 7, "seq": 3, "kind": "full", "supersedes_before_seq": 3}},
        {"puter_use": {"window_id": 7, "seq": 4, "kind": "zoom", "supersedes_before_seq": 3}},
    ]
    assert all(isinstance(r[1], str) for r in results)  # the text, as ever


def test_image_meta_goes_on_the_wire_and_on_error_results(server):
    m = server(PUTER_USE_IMAGE_META="1")
    fake_helper(m, [shot(7), shot(7, done=0, total=1, errors=['action 1 (click): nothing shows "Nope"'])])
    out = asyncio.run(m.mcp.call_tool("screenshot", {"window": 7}))
    block = out.model_dump(by_alias=True, mode="json")["content"][0]
    assert block["type"] == "image" and block["_meta"] == {
        "puter_use": {"window_id": 7, "seq": 1, "kind": "full", "supersedes_before_seq": 1}}
    failed = asyncio.run(m.act([m.Action(type="click", target="Nope")], window=7))
    assert failed.is_error is True and [c.type for c in failed.content] == ["image", "text"]
    assert failed.content[0].meta["puter_use"]["seq"] == 2


def test_without_image_meta_images_are_as_ever(server):
    from mcp.server.mcpserver import Image

    m = server()
    fake_helper(m, [shot(7)])
    out = asyncio.run(m.screenshot(window=7))
    assert isinstance(out[0], Image) and out[0].data == m.image_bytes(shot(7), out[1])[0]


def test_a_crop_is_numbered_against_the_last_whole_image(server):
    m = server(PUTER_USE_IMAGE_META="1")
    fake_helper(m, [shot(7), shot(7, done=1, total=1, crop=[10, 10, 30, 20])])
    asyncio.run(m.screenshot(window=7))
    out = asyncio.run(m.act([m.Action(type="click", target="OK")], window=7))
    assert out[0].meta == {"puter_use": {"window_id": 7, "seq": 2, "kind": "crop", "supersedes_before_seq": 1}}


# -- the helper is asked to check edits only when an image would be kept out for it


@pytest.mark.parametrize("env, asked", [
    ({}, False),
    ({"PUTER_USE_IMAGE_META": "1"}, False),
    ({"PUTER_USE_IMAGE_DELIVERY": "inline", "PUTER_USE_OMIT_VERIFIED": "0"}, False),
    ({"PUTER_USE_OMIT_VERIFIED": "1"}, True),
    ({"PUTER_USE_IMAGE_DELIVERY": "hybrid"}, True),
])
def test_act_asks_the_helper_to_check_edits_only_when_opted_in(monkeypatch, env, asked):
    from puter_use import mcp_server as m
    from puter_use.settings import act_params

    for name in TOGGLES:
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    seen = []

    async def fake_consent(ctx, params):
        seen.append(params)
        return {"window": {"id": 1, "app": "X"}, "done": 1, "total": 1, "changed": False}

    monkeypatch.setattr(m, "_run_with_consent", fake_consent)
    monkeypatch.setattr(m, "helper", Helper("t"))
    asyncio.run(m.mcp.call_tool("act", {"actions": [{"type": "click", "target": "OK"}]}))
    assert seen[0].get("verify_edits") is (True if asked else None)
    assert "verify_edits" not in act_params("auto")  # the CLI and code mode never ask


# -- PUTER_USE_IMAGE_DELIVERY=hybrid


def test_hybrid_delivery_saves_a_checked_edit_and_says_where(server, tmp_path):
    from mcp.server.mcpserver import Image

    from puter_use.present import IMAGE_SAVED

    m = server(PUTER_USE_IMAGE_DELIVERY="hybrid")
    m.image_dir = lambda: tmp_path
    got = fake_helper(m, [shot(7), edit(7, change_box=[1, 2, 30, 20], change_fraction=0.1,
                                        notes=["typed into Name"])])
    looked = asyncio.run(m.screenshot(window=7))
    assert isinstance(looked[0], Image)  # a screenshot is always in its result
    out = asyncio.run(m.act([m.Action(**TYPE_ADA)], window=7))
    assert "verify_edits" not in got[0][1] and got[1][1]["verify_edits"] is True
    [text] = out
    saved = tmp_path / "t" / "7-2.png"
    assert text.splitlines() == ['Probe #7 "w" · changed in (1,2)-(30,20)', IMAGE_SAVED.format(path=saved),
                                 "note: typed into Name"]
    assert saved.read_bytes() == m.image_bytes(edit(7))[0] and saved.read_bytes()[:4] == b"\x89PNG"


def test_hybrid_delivery_never_holds_back_a_screenshot(server, tmp_path):
    m = server(PUTER_USE_IMAGE_DELIVERY="hybrid", PUTER_USE_OMIT_VERIFIED="1")
    m.image_dir = lambda: tmp_path
    fake_helper(m, [shot(7), shot(7, verified=True)])  # (even one that says verified)
    assert has_image(asyncio.run(m.screenshot(window=7)))
    assert has_image(asyncio.run(m.screenshot(window=7)))
    assert not list(tmp_path.rglob("*.png"))


def test_with_both_set_hybrid_delivery_wins(server, tmp_path):
    m = server(PUTER_USE_IMAGE_DELIVERY="hybrid", PUTER_USE_OMIT_VERIFIED="1")
    m.image_dir = lambda: tmp_path
    fake_helper(m, [shot(7), edit(7)])
    asyncio.run(m.screenshot(window=7))
    [text] = asyncio.run(m.act([m.Action(**TYPE_ADA)], window=7))
    assert "image saved (the edit checked out by accessibility): " in text and (tmp_path / "t" / "7-2.png").exists()


def test_a_hybrid_image_that_cannot_be_saved_goes_in_the_result(server, tmp_path):
    m = server(PUTER_USE_IMAGE_DELIVERY="hybrid")
    blocked = tmp_path / "a file"
    blocked.write_text("")
    m.image_dir = lambda: blocked  # its session folder can't be made
    fake_helper(m, [shot(7), edit(7)])
    asyncio.run(m.screenshot(window=7))
    out = asyncio.run(m.act([m.Action(**TYPE_ADA)], window=7))
    assert has_image(out) and "image saved" not in out[-1]


def test_hybrid_delivery_keeps_only_the_newest_images_of_a_session(server, tmp_path):
    m = server(PUTER_USE_IMAGE_DELIVERY="hybrid")
    m.image_dir = lambda: tmp_path
    m.helper = Helper("mcp/../odd session")  # (any name makes a folder of its own, inside image_dir)
    m.SHOTS_KEPT = 3
    paths = []
    for i in range(5):
        paths.append(Path(m._save_image(edit(7))))
        os.utime(paths[-1], (1000 + i, 1000 + i))  # (in order, however fine the clock)
    folder = paths[0].parent
    assert folder.parent == tmp_path and folder.name == "mcp_.._odd_session"
    assert sorted(p.name for p in folder.iterdir()) == ["7-3.png", "7-4.png", "7-5.png"]


# -- PUTER_USE_OMIT_VERIFIED=1


def test_omit_verified_leaves_out_the_image_only_of_a_checked_edit(server):
    from mcp.server.mcpserver import Image

    from puter_use.present import IMAGE_OMITTED

    m = server(PUTER_USE_OMIT_VERIFIED="1")
    got = fake_helper(m, [shot(7), edit(7), shot(7, done=1, total=1)])
    asyncio.run(m.screenshot(window=7))
    assert asyncio.run(m.act([m.Action(**TYPE_ADA)], window=7)) == [f'Probe #7 "w"\n{IMAGE_OMITTED}']
    assert got[1][1]["verify_edits"] is True
    unchecked = asyncio.run(m.act([m.Action(type="click", target="OK")], window=7))
    assert isinstance(unchecked[0], Image) and unchecked[1] == 'Probe #7 "w" · image 40x30'


@pytest.mark.parametrize("mode", [{"PUTER_USE_OMIT_VERIFIED": "1"}, {"PUTER_USE_IMAGE_DELIVERY": "hybrid"}])
@pytest.mark.parametrize("change", [
    {"verified": False},
    {"verified": "yes"},
    {"errors": ['action 1 (type): nothing shows "Name"'], "done": 0},
    {"stopped": "stopped before action 2 (click): pressing “Send” may not be undoable; it was not run. Ask the user",
     "total": 2},
    {"done": 1, "total": 2},
    {"card": "shortcuts: Toggle Thing cmd+option+t"},
    {"closed": True},
    {"window": {"id": 8, "app": "Probe", "title": "a new one"}},
])
def test_every_other_act_image_goes_in_the_result(server, tmp_path, mode, change):
    """Kept out only for an edit the helper checked: never for a failure, a stop, a batch cut short, the first
    look at an app, a closed window or one the agent hasn't had a whole image of yet."""
    m = server(**mode)
    m.image_dir = lambda: tmp_path
    fake_helper(m, [shot(7), edit(7, **change)])
    asyncio.run(m.screenshot(window=7))
    out = asyncio.run(m.act([m.Action(**TYPE_ADA)], window=7))
    assert has_image(out)
    assert not list(tmp_path.rglob("*.png"))


@pytest.mark.parametrize("mode", [{"PUTER_USE_OMIT_VERIFIED": "1"}, {"PUTER_USE_IMAGE_DELIVERY": "hybrid"}])
def test_a_press_given_confirm_or_allowed_by_the_user_keeps_its_image(server, tmp_path, mode):
    m = server(**mode)
    m.image_dir = lambda: tmp_path
    fake_helper(m, [shot(7), edit(7)])
    asyncio.run(m.screenshot(window=7))
    assert has_image(asyncio.run(m.act([m.Action(type="click", target="Send", confirm=True)], window=7)))

    async def allowed(ctx, params):  # the user said yes to a press the batch stopped before
        return edit(7, notes=["the user allowed pressing “Send”"], allowed=True)

    m._run_with_consent = allowed
    assert has_image(asyncio.run(m.act([m.Action(type="click", target="Send")], window=7)))
    assert not list(tmp_path.rglob("*.png"))


def test_the_consent_flow_marks_a_batch_the_user_allowed(server):
    m = server(PUTER_USE_OMIT_VERIFIED="1")
    stop = {"done": 1, "total": 2, "stopped": "…", "confirm": {"action": 2, "label": "Send",
                                                              "rest": [{"type": "click", "target": "Send"}]}}
    replies = [stop, edit(7)]

    async def fake_call(cmd, **params):
        return replies.pop(0)

    async def yes(ctx, confirm):
        return True

    m._call, m._ask_user = fake_call, yes
    res = asyncio.run(m._run_with_consent(object(), {"actions": [{}, {}]}))
    assert res["allowed"] is True and res["done"] == res["total"] == 2
    m._whole_seq[7] = 1  # (the agent has seen the window)
    assert m._withholding(res, [{}, {}]) is None
    assert m._withholding({k: v for k, v in res.items() if k != "allowed"}, [{}, {}]) == "omit"


# -- what a kept-out image costs in the token log


def test_a_left_out_image_logs_no_image_and_its_line_as_status(server, tmp_path, monkeypatch):
    from puter_use.present import IMAGE_OMITTED

    m = server(PUTER_USE_OMIT_VERIFIED="1")
    log = tmp_path / "tokens.jsonl"
    monkeypatch.setenv("PUTER_USE_TOKEN_LOG", str(log))
    fake_helper(m, [shot(7), edit(7, notes=["typed into Name"])])
    asyncio.run(m.screenshot(window=7))
    [text] = asyncio.run(m.act([m.Action(**TYPE_ADA)], window=7))
    call = [json.loads(line) for line in log.read_text().splitlines()][-1]
    assert call["tool"] == "act" and call["images"] == [] and call["text_bytes"] == len(text.encode())
    assert call["split"]["notes"] == len("note: typed into Name")
    assert sum(call["split"].values()) == call["text_bytes"]
    assert call["split"]["status"] == len(f'Probe #7 "w"\n{IMAGE_OMITTED}\n'.encode())


def test_the_text_without_an_image_says_so_after_the_status_line():
    from puter_use.present import without_image

    res = edit(7, change_box=[1, 2, 30, 20], change_fraction=0.1, notes=["typed into Name"], text='[3] field "Name"')
    assert without_image(res, "no image: …").splitlines() == [
        'Probe #7 "w" · changed in (1,2)-(30,20)', "no image: …", "note: typed into Name", '[3] field "Name"']
    assert without_image({}, "no image: …") == "no image: …"


def test_crop_changes_and_low_detail_change_results_only(server):
    """PUTER_USE_CROP_CHANGES and PUTER_USE_DETAIL are read per call: what a server advertises is the same
    with them, in every profile, and act's description and the instructions are as written."""
    for profile in ({}, {"PUTER_USE_SCHEMA": "thin"}, {"PUTER_USE_MACROS": "0"}):
        plain = surface(server(**profile))
        m = server(**profile, PUTER_USE_CROP_CHANGES="1", PUTER_USE_DETAIL="low")
        assert surface(m) == plain
    m = server(PUTER_USE_CROP_CHANGES="1", PUTER_USE_DETAIL="low")
    assert m.act.__doc__ == m.act.__wrapped__.__doc__ and len(m.act.__doc__) < 4096
    for name in ("act", "screenshot"):
        assert tools_of(m)[name].input_schema["properties"]["detail"] == {"enum": ["low", "normal"], "type": "string"}
    assert "crop_changes" in tools_of(m)["act"].input_schema["properties"]
    assert "crop_changes" not in tools_of(m)["screenshot"].input_schema["properties"]
