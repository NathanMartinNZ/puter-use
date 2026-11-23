import pytest

from puter_use.cli import build_action, parser, save_as_arg


class FakeHelper:
    """Stands in for the helper connection: records calls, answers from a script."""

    def __init__(self, answers=None):
        self.calls = []
        self.answers = answers or {}

    async def call(self, cmd, autostart=True, **params):
        self.calls.append((cmd, {k: v for k, v in params.items() if v is not None}))
        ans = self.answers.get(cmd, {})
        return ans(params) if callable(ans) else ans

    async def close(self):
        pass


def computer(answers=None):
    from puter_use.api import Computer

    c = Computer("Probe")
    c._helper = FakeHelper(answers)
    return c


def test_cli_macros():
    p = parser()
    assert build_action(p.parse_args(["macro", "export", "file=a b.pdf", "n=2"])) == {
        "type": "macro", "name": "export", "vars": {"file": "a b.pdf", "n": "2"}}
    assert build_action(p.parse_args(["macro", "export"])) == {"type": "macro", "name": "export"}
    assert save_as_arg(p.parse_args(["act", "[]", "--save-as", "x"])) == "x"
    assert save_as_arg(p.parse_args(["act", "[]", "--save-as", "x", "--var", "who=Ada", "--describe", "d"])) == {
        "name": "x", "vars": {"who": "Ada"}, "description": "d"}
    assert save_as_arg(p.parse_args(["act", "[]"])) is None
    with pytest.raises(SystemExit):
        build_action(p.parse_args(["macro", "export", "novalue"]))
    a = p.parse_args(["macros", "--all"])
    assert a.all and a.delete is None


def test_mcp_macro_schema():
    import asyncio

    from puter_use.mcp_server import Action, mcp

    a = Action(type="macro", name="export", vars={"file": "x.pdf"})
    assert a.model_dump(exclude_none=True) == {"type": "macro", "name": "export", "vars": {"file": "x.pdf"}}
    tools = {t.name: t for t in asyncio.run(mcp.list_tools())}
    assert "macros" in tools and "save_as" in tools["act"].input_schema["properties"]


def test_api_actions_become_act_calls():
    from puter_use.api import Computer

    ok = {"window": {"id": 9, "app": "Probe"}, "done": 1, "total": 1, "changed": False}
    c = computer({"act": ok})
    c.click("Save")
    c.type("Ada", into="Name", clear=True)
    c.fill({"Name": "Grace", "Subscribe": True}, submit="Save")
    c.click(14, count=2)
    c.key("Tab", repeat=3)
    c.macro("export", file="a.pdf")
    c.wait_for("Done", gone=True)
    c.wait_for(change=True, timeout_ms=4000)
    acts = [p["actions"][0] for cmd, p in c._helper.calls]
    assert acts[6] == {"type": "wait_for", "timeout_ms": 5000, "text": "Done", "gone": True}
    assert acts[7] == {"type": "wait_for", "timeout_ms": 4000, "change": True}
    assert acts[0] == {"type": "click", "target": "Save"}
    assert acts[1] == {"type": "type", "text": "Ada", "target": "Name", "clear": True}
    assert acts[2]["fields"] == {"Name": "Grace", "Subscribe": True}  # by label, as act takes them
    assert acts[2]["submit"] == "Save"
    assert acts[3] == {"type": "double_click", "element": 14}
    assert acts[4] == {"type": "keypress", "keys": "Tab", "repeat": 3}
    assert acts[5] == {"type": "macro", "name": "export", "vars": {"file": "a.pdf"}}
    first = c._helper.calls[0][1]
    assert first["window"] == "Probe" and first["screenshot"] is False  # scripts don't look by default
    assert c.window == 9  # it follows the window act reports
    assert isinstance(c, Computer)


def test_api_takes_an_outlines_numbers_and_a_page_wait():
    ok = {"window": {"id": 9, "app": "Probe"}, "done": 1, "total": 1}
    c = computer({"act": ok, "screenshot": {"read": "x", "read_range": [0, 1, 1]}})
    c.click("#14")
    c.type("Ada", into="#3")
    c.click("#tag")
    c.navigate("https://example.com", timeout_ms=20000)
    c.navigate("https://example.com")
    c.act({"type": "fill", "fields": [{"element": "#5", "text": "Ada"}], "submit": "#7"})
    c.read("#12")
    acts = [p["actions"][0] for cmd, p in c._helper.calls if cmd == "act"]
    assert acts[5] == {"type": "fill", "fields": [{"element": 5, "text": "Ada"}], "submit": 7}
    assert acts[0] == {"type": "click", "element": 14}
    assert acts[1] == {"type": "type", "text": "Ada", "element": 3}
    assert acts[2] == {"type": "click", "target": "#tag"}
    assert acts[3] == {"type": "navigate", "url": "https://example.com", "timeout_ms": 20000}
    assert acts[4] == {"type": "navigate", "url": "https://example.com"}
    assert c._helper.calls[-1] == ("screenshot", {"window": 9, "read": 12, "offset": 0, "limit": 50000})


def test_api_raises_on_failed_action():
    from puter_use.api import ActionError

    c = computer({"act": {"window": {"id": 9, "app": "Probe"}, "done": 0, "total": 1,
                          "errors": ["action 1 (click): nothing shows \"Sve\""]}})
    with pytest.raises(ActionError) as e:
        c.click("Sve")
    assert "nothing shows" in str(e.value) and not e.value.result.ok
    assert c.act({"type": "click", "target": "Sve"}, check=False).ok is False


def test_api_find_parses_matches():
    text = ('[5] button "Save" at (120,40)\npartial matches (target one by its whole text or number):\n'
            '[31] text "Save as…" at (300,90)')
    c = computer({"find": {"window": {"id": 9}, "text": text}})
    hits = c.find("Save")
    assert hits[0] == {"element": 5, "role": "button", "label": "Save", "x": 120, "y": 40}
    assert hits[1]["element"] == 31 and len(hits) == 2
    assert c.exists("Save")
    # Text read off the screen has no number to act on; what's similar to a miss isn't a match.
    for text in ['(read off the screen: click these by x,y)\ntext "Save" at (1,2)',
                 '(nothing shows "Sve") similar:\n[5] button "Save" at (120,40)']:
        c = computer({"find": {"window": {"id": 9}, "text": text}})
        assert c.find("Sve") == [] and not c.exists("Sve")


def test_api_find_by_role_alone():
    text = 'role "field", the first 2 of 3 (add a query to narrow it):\n[3] field "Email" at (10,20)\n' \
           '[4] field "Password" (off screen)\n+1 more'
    c = computer({"find": {"window": {"id": 9}, "text": text}})
    hits = c.find(role="field")
    assert [h["element"] for h in hits] == [3, 4] and hits[1]["x"] is None and "query" not in hits[0]
    cmd, params = c._helper.calls[-1]
    assert cmd == "find" and params["window"] == "Probe" and params["role"] == "field"
    assert "query" not in params and "queries" not in params
    assert c.exists(role="field")


def test_api_find_of_several_texts_is_one_call_with_a_part_each():
    text = "\n".join([
        '"Name":', '[3] field "Name" at (10,20)',
        '"Save":', '[5] button "Save" at (120,40)', "partial matches (target one by its whole text or number):",
        '[31] text "Save as…" at (300,90)', "(more may be off screen: the search there stopped early)",
        '(nothing shows "Nope"; similar: [9] button "Nape" at (1,2))',
        '"Sign in":', '(read off the screen: click these by x,y)', 'text "Sign in" at (40,50)',
        '("Go" wasn\'t looked for: the others took the time; find it on its own)',
    ])
    c = computer({"find": {"window": {"id": 9}, "text": text}})
    hits = c.find(["Name", "Save", "", "Name", "Nope", "Sign in", "Go"])
    cmd, params = c._helper.calls[-1]
    assert cmd == "find" and params["queries"] == ["Name", "Save", "Nope", "Sign in", "Go"] and "query" not in params
    assert [(h["query"], h["element"]) for h in hits] == [("Name", 3), ("Save", 5), ("Save", 31)]
    # One text in a list reads as a find of it alone.
    c = computer({"find": {"window": {"id": 9}, "text": '[3] field "Name" at (10,20)'}})
    assert c.find(["Name"]) == [{"element": 3, "role": "field", "label": "Name", "x": 10, "y": 20, "query": "Name"}]


def test_api_scroll_of_nothing_is_refused_before_it_is_sent():
    c = computer({"act": {"window": {"id": 9, "app": "Probe"}, "done": 1, "total": 1}})
    with pytest.raises(ValueError, match="dy"):
        c.scroll()
    assert c._helper.calls == []
    c.scroll(300)
    c.scroll(dx=-40, at="List")
    acts = [p["actions"][0] for _, p in c._helper.calls]
    assert acts[0] == {"type": "scroll", "scroll_y": 300, "scroll_x": 0}
    assert acts[1] == {"type": "scroll", "scroll_y": 0, "scroll_x": -40, "target": "List"}


def test_api_fill_sends_fields_by_label_as_they_are():
    ok = {"window": {"id": 9, "app": "Probe"}, "done": 1, "total": 1}
    c = computer({"act": ok})
    fields = {"Email": "ada@example.com", "Country": "NZ", "I agree": True}
    c.fill(fields, submit=True)
    c.fill([{"target": "Size", "option": "L"}], submit="#7")
    acts = [p["actions"][0] for _, p in c._helper.calls]
    assert acts[0] == {"type": "fill", "fields": fields, "submit": True}
    assert acts[1] == {"type": "fill", "fields": [{"target": "Size", "option": "L"}], "submit": 7}
    assert fields == {"Email": "ada@example.com", "Country": "NZ", "I agree": True}  # the caller's own is untouched


def test_api_scroll_until_a_text():
    from puter_use.api import ActionError

    found = {"window": {"id": 9, "app": "Probe"}, "done": 1, "total": 1,
             "notes": ['scrolled 2 times; found [12] button "Load more" at (340,512)']}
    c = computer({"act": found})
    res = c.scroll(until="Load more")
    c.scroll(400, until={"text": "Total", "role": "text"}, max_scrolls=15, at="List")
    acts = [p["actions"][0] for _, p in c._helper.calls]
    assert acts[0] == {"type": "scroll", "until": "Load more"}  # no distance: a screenful at a time
    assert acts[1] == {"type": "scroll", "until": {"text": "Total", "role": "text"}, "scroll_y": 400,
                       "max_scrolls": 15, "target": "List"}
    assert 'found [12] button "Load more"' in res.text
    # Alone in its batch, a scroll that doesn't find its text gets only a note: a script stops there.
    missed = {**found, "notes": ['action 1 (scroll): reached the bottom after 4 scrolls; "Nope" not found']}
    c = computer({"act": missed})
    with pytest.raises(ActionError, match="not found"):
        c.scroll(until="Nope")
    with pytest.raises(TypeError, match="until"):
        c.scroll(300, max_scrolls=3)
    assert len(c._helper.calls) == 1


def test_api_act_with_no_window_passes_open_and_navigate_through():
    from puter_use.api import Computer

    c = Computer()
    c._helper = FakeHelper({"act": {"window": {"id": 12, "app": "Preview"}, "done": 1, "total": 1}})
    c.open("/tmp/report.pdf")
    cmd, params = c._helper.calls[-1]
    assert cmd == "act" and "window" not in params and params["actions"] == [{"type": "open", "path": "/tmp/report.pdf"}]
    assert c.window == 12  # on the window open brought up from then on
    # open that brought up no window of its own: no window in the reply, and none taken.
    c = Computer()
    c._helper = FakeHelper({"act": {"done": 1, "total": 1, "notes": ["no new window appeared"]}})
    assert c.navigate("https://example.com").ok and c.window is None
    assert "window" not in c._helper.calls[-1][1]


def test_exec_runs_a_script(monkeypatch, capsys):
    import puter_use.api as api
    from puter_use.cli import run_script

    made = []

    class Stub(api.Computer):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            self._helper = FakeHelper({"act": {"window": {"id": 3, "app": "Probe"}, "done": 1, "total": 1}})
            made.append(self)

    monkeypatch.setattr(api, "Computer", Stub)
    args = parser().parse_args(["exec", "-c", "pu.key('cmd+a'); print('window', pu.window, sys.argv[1:])", "-w",
                                "Probe"])
    args.code = "import sys\n" + args.code
    args.args = ["x"]
    assert run_script(args) == 0
    assert "window 3 ['x']" in capsys.readouterr().out
    args.code = "pu.act({'type': 'click'}, check=True) if False else (_ for _ in ()).throw(ValueError('boom'))"
    assert run_script(args) == 1


def test_policy_shown_in_window_list():
    from puter_use.present import window_list

    res = {"windows": [{"id": 1, "app": "Terminal", "title": "zsh", "frame": [0, 0, 600, 400], "on_screen": True,
                        "policy": "click"},
                       {"id": 2, "app": "1Password", "title": "", "frame": [0, 0, 600, 400], "on_screen": True,
                        "policy": "deny"}],
           "permissions": {}, "notes": ["policy: bad file"]}
    out = window_list(res).splitlines()
    assert out == ['Terminal · clicks only, no typing (policy): 1 "zsh"', "1Password · off limits (policy): 2 untitled",
                   "note: policy: bad file"]


def test_cli_confirm_flag():
    p = parser()
    assert build_action(p.parse_args(["click", "-e", "Delete", "--confirm"])) == {
        "type": "click", "confirm": True, "target": "Delete"}
    assert build_action(p.parse_args(["perform", "Send", "press", "--confirm"]))["confirm"] is True
    assert build_action(p.parse_args(["macro", "send-it", "--confirm"]))["confirm"] is True
    assert "confirm" not in build_action(p.parse_args(["click", "-e", "Delete"]))


def _consent_run(answers, allowed, actions=3):
    import asyncio

    import puter_use.mcp_server as m

    calls = []

    async def fake_call(cmd, **params):
        calls.append(params)
        return answers[len(calls) - 1]

    async def fake_ask(ctx, confirm):
        return allowed

    orig = (m._call, m._ask_user)
    m._call, m._ask_user = fake_call, fake_ask
    try:
        res = asyncio.run(m._run_with_consent(object(), {"actions": [{}] * actions, "save_as": "x"}))
    finally:
        m._call, m._ask_user = orig
    return res, calls


def test_mcp_asks_the_user_and_carries_on():
    stop = {"done": 1, "total": 3, "stopped": "stopped before action 2 …",
            "notes": ["not saved as a macro: only a batch that runs to the end is"],
            "confirm": {"action": 2, "label": "Delete", "rest": [{"type": "click", "target": "Delete"}, {"type": "x"}],
                        "recorded": [{"type": "click", "target": "Name"}]}}
    after = {"done": 2, "total": 2, "notes": ["saved macro \"x\""]}
    res, calls = _consent_run([stop, after], True)
    assert calls[1]["actions"][0] == {"type": "click", "target": "Delete", "confirm": True}
    # save_as goes along with the steps recorded before the stop, so the whole batch is saved
    assert calls[1]["first"] == 2 and calls[1]["save_as"] == "x"
    assert calls[1]["recorded"] == [{"type": "click", "target": "Name"}]
    assert res["done"] == 3 and res["total"] == 3 and "confirm" not in res
    assert any("allowed" in n for n in res["notes"])
    assert not any(n.startswith("not saved") for n in res["notes"])


def test_mcp_keeps_what_the_batch_read_before_the_users_ok():
    """Text read before the stop comes first in the result, then what the rest of the batch read."""
    first = {"read": "before", "read_of": '[3] field "Name"', "read_range": [0, 6, 6]}
    second = {"read": "after", "read_of": "region (0,0)-(10,10)"}
    stop = {"done": 1, "total": 3, "stopped": "…", "reads": [first],
            "confirm": {"action": 2, "label": "Delete", "rest": [{"type": "click"}, {"type": "read"}]}}
    res, calls = _consent_run([stop, {"done": 2, "total": 2, "reads": [second]}], True)
    assert len(calls) == 2 and res["reads"] == [first, second]
    res, _ = _consent_run([dict(stop), {"done": 2, "total": 2}], True)  # nothing read after the stop
    assert res["reads"] == [first]
    res, _ = _consent_run([{k: v for k, v in stop.items() if k != "reads"}, {"done": 2, "total": 2}], True)
    assert "reads" not in res  # nothing read at all


def test_mcp_counts_a_macro_as_its_steps():
    # one macro action that runs 4 steps: the numbers are the helper's, not the 1 action passed in
    stop = {"done": 1, "total": 4, "stopped": "…",
            "confirm": {"action": 2, "label": "Delete", "rest": [{"type": "click"}, {}, {}]}}
    after = {"done": 3, "total": 3}
    res, _ = _consent_run([stop, after], True, actions=1)
    assert res["done"] == 4 and res["total"] == 4
    res, _ = _consent_run([dict(stop)], False, actions=1)
    assert "actions 2-4 were not run" in res["stopped"]


def test_mcp_user_says_no():
    stop = {"done": 1, "total": 3, "stopped": "…",
            "confirm": {"action": 2, "label": "Delete", "rest": [{"type": "click"}]}}
    res, calls = _consent_run([stop], False)
    assert len(calls) == 1 and "the user said no" in res["stopped"] and "confirm" not in res
    assert res["declined"] is True  # an error result: nothing the agent asked for happened


def test_mcp_declined_is_an_error_result():
    import asyncio

    import puter_use.mcp_server as m

    async def fake_consent(ctx, params):
        return {"done": 0, "total": 1, "stopped": "the user said no", "declined": True}

    orig = m._run_with_consent
    m._run_with_consent = fake_consent
    try:
        out = asyncio.run(m.act([m.Action(type="click", target="Delete")]))
    finally:
        m._run_with_consent = orig
    assert out.is_error is True


def test_mcp_failed_first_look_keeps_its_image(monkeypatch):
    """A first act whose first action fails comes with the window's image: the error result carries it."""
    import asyncio
    import base64
    import io

    from PIL import Image as PILImage

    import puter_use.mcp_server as m

    buf = io.BytesIO()
    PILImage.new("RGB", (40, 30), "white").save(buf, "PNG")

    async def fake_consent(ctx, params):
        return {"done": 0, "total": 1, "errors": ['action 1 (click): nothing shows "No such button"'],
                "image": base64.b64encode(buf.getvalue()).decode(), "mime": "image/png", "width": 40,
                "height": 30, "zoom": False, "window": {"id": 7, "app": "App", "title": "w"}, "changed": True}

    monkeypatch.setattr(m, "_run_with_consent", fake_consent)
    out = asyncio.run(m.act([m.Action(type="click", target="No such button")]))
    assert out.is_error is True
    assert [c.type for c in out.content] == ["image", "text"]
    assert "App #7 \"w\" · image 40x30 · ran 0/1 actions" in out.content[1].text
    assert 'error: action 1 (click): nothing shows "No such button"' in out.content[1].text


def test_mcp_without_elicitation_passes_the_stop_on():
    stop = {"done": 1, "total": 3, "stopped": "… Ask the user", "confirm": {"action": 2, "label": "Delete",
                                                                           "rest": [{"type": "click"}]}}
    res, calls = _consent_run([stop], None)
    assert len(calls) == 1 and res["stopped"] == "… Ask the user"


def test_exec_c_passes_every_argument(capsys):
    from puter_use.cli import parser, run_script

    args = parser().parse_args(["exec", "-c", "import sys; print(sys.argv[1:])", "a", "b", "c"])
    assert run_script(args) == 0
    assert capsys.readouterr().out.strip() == "['a', 'b', 'c']"


def test_exec_reports_a_message_exit(capsys):
    from puter_use.cli import parser, run_script

    assert run_script(parser().parse_args(["exec", "-c", "raise SystemExit('bye')"])) == 1
    assert "bye" in capsys.readouterr().err


def test_var_needs_save_as():
    import pytest

    from puter_use.cli import parser, save_as_arg

    with pytest.raises(SystemExit, match="--save-as"):
        save_as_arg(parser().parse_args(["act", "[]", "--var", "x=1"]))


def test_window_list_names_the_apps_it_leaves_out():
    from puter_use.present import window_list

    out = window_list({"windows": [], "notes": ["not listed: 1Password (puter-use's policy keeps agents out)"]})
    assert out.splitlines() == ["no windows", "note: not listed: 1Password (puter-use's policy keeps agents out)"]


def test_act_confirm_flag_points_at_the_action(capsys):
    import asyncio

    from puter_use.cli import parser, run

    args = parser().parse_args(["act", "--confirm", "-w", "1", "[]"])
    assert asyncio.run(run(args)) == 2
    assert '"confirm": true on the action' in capsys.readouterr().err


def test_api_sends_crop_changes_and_detail_only_when_asked(monkeypatch):
    """act takes crop_changes and detail, and screenshot detail, sent only when on; act's go by
    PUTER_USE_CROP_CHANGES and PUTER_USE_DETAIL when not given, a screenshot's only by its own say."""
    for name in ("PUTER_USE_CROP_CHANGES", "PUTER_USE_DETAIL"):
        monkeypatch.delenv(name, raising=False)
    win = {"id": 9, "app": "Probe"}
    c = computer({"act": {"window": win, "done": 1, "total": 1, "changed": False}, "screenshot": {"window": win}})
    c.click("Save")
    c.act({"type": "click", "target": "Save"}, crop_changes=True, detail="low")
    c.screenshot()
    c.screenshot(detail="low")
    monkeypatch.setenv("PUTER_USE_CROP_CHANGES", "1")
    monkeypatch.setenv("PUTER_USE_DETAIL", "low")
    c.key("Return")
    c.screenshot()
    c.act({"type": "keypress", "keys": "Tab"}, crop_changes=False, detail="normal")
    sent = [p for _, p in c._helper.calls]
    assert not {"crop_changes", "detail"} & set(sent[0])
    assert sent[1]["crop_changes"] is True and sent[1]["detail"] == "low"
    assert "detail" not in sent[2] and sent[3]["detail"] == "low"
    assert sent[4]["crop_changes"] is True and sent[4]["detail"] == "low"  # the environment's
    assert "detail" not in sent[5] and "crop_changes" not in sent[5]
    assert not {"crop_changes", "detail"} & set(sent[6])  # the call's own say wins
