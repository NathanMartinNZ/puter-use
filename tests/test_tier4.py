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
    acts = [p["actions"][0] for cmd, p in c._helper.calls]
    assert acts[0] == {"type": "click", "target": "Save"}
    assert acts[1] == {"type": "type", "text": "Ada", "target": "Name", "clear": True}
    assert acts[2]["fields"] == [{"target": "Name", "text": "Grace"}, {"target": "Subscribe", "checked": True}]
    assert acts[2]["submit"] == "Save"
    assert acts[3] == {"type": "double_click", "element": 14}
    assert acts[4] == {"type": "keypress", "keys": "Tab", "repeat": 3}
    assert acts[5] == {"type": "macro", "name": "export", "vars": {"file": "a.pdf"}}
    first = c._helper.calls[0][1]
    assert first["window"] == "Probe" and first["screenshot"] is False  # scripts don't look by default
    assert c.window == 9  # it follows the window act reports
    assert isinstance(c, Computer)


def test_api_raises_on_failed_action():
    from puter_use.api import ActionError

    c = computer({"act": {"window": {"id": 9, "app": "Probe"}, "done": 0, "total": 1,
                          "errors": ["action 1 (click): nothing shows \"Sve\""]}})
    with pytest.raises(ActionError) as e:
        c.click("Sve")
    assert "nothing shows" in str(e.value) and not e.value.result.ok
    assert c.act({"type": "click", "target": "Sve"}, check=False).ok is False


def test_api_find_parses_matches():
    text = '[5] button "Save" at (120,40)\n[31] text "Save as…" at (300,90)\ntext "x" at (1,2) (read off the screen: click it by x,y)'
    c = computer({"find": {"window": {"id": 9}, "text": text}})
    hits = c.find("Save")
    assert hits[0] == {"element": 5, "role": "button", "label": "Save", "x": 120, "y": 40}
    assert hits[1]["element"] == 31 and len(hits) == 2
    assert c.exists("Save")


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
    assert out[0].endswith("clicks only, no typing (policy)") and out[1].endswith("off limits (policy)")
    assert out[2] == "note: policy: bad file"


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
