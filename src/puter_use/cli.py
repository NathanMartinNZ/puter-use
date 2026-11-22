"""puter-use CLI: the same windows/screenshot/act loop for harnesses that drive tools via shell.

Screenshots are written to files (path printed) so any agent that can view images can use them.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import sys
import time
from pathlib import Path

from .client import Helper, HelperError, app_path
from .present import HIDDEN_CAP, image_bytes, summarize, until_missed, window_list
from .settings import (act_params, capture_params, detail_param, element_number, element_numbers, outline_params,
                       session)

SHOTS = Path(os.environ.get("PUTER_USE_SHOTS") or Path.home() / "Library/Caches/puter-use/shots")


def save_image(res: dict) -> str | None:
    img = image_bytes(res)
    if not img:
        return None
    SHOTS.mkdir(parents=True, exist_ok=True)
    ext = {"image/png": "png", "image/webp": "webp"}.get(img[1], "jpg")
    path = SHOTS / f"{time.strftime('%H%M%S')}-{time.monotonic_ns() % 10**6:06d}.{ext}"
    path.write_bytes(img[0])
    try:  # the oldest go; only files (a folder someone put there stays)
        for old in sorted((p for p in SHOTS.iterdir() if p.is_file()), key=lambda p: p.stat().st_mtime)[:-40]:
            old.unlink(missing_ok=True)
    except OSError:  # (another process clearing up at the same time): next time
        pass
    return str(path)


def report(res: dict, missed: bool = False) -> int:
    """Print the result; the exit status is 1 if an action failed or the batch stopped early (`missed`: the
    command's own scroll until a text shows didn't find it, `until_missed`)."""
    print(summarize(res))
    path = save_image(res)
    if path:
        print(f"image: {path}")
    return 1 if res.get("errors") or res.get("stopped") or (missed and until_missed(res)) else 0


def parse_region(s: str | None) -> list[int] | None:
    if not s:
        return None
    vals = [int(float(v)) for v in s.replace(" ", "").split(",")]
    if len(vals) != 4:
        raise SystemExit("--region needs x0,y0,x1,y1")
    return vals


def window_arg(v: str | None):
    if v is None:
        return None
    return int(v) if v.isdigit() else v


def parse_vars(items: list[str] | None) -> dict[str, str]:
    out = {}
    for item in items or []:
        k, sep, v = item.partition("=")
        if not sep or not k:
            raise SystemExit(f"variables are NAME=VALUE, not {item!r}")
        out[k] = v
    return out


def parse_fields(items: list[str]) -> dict:
    """fill's LABEL=VALUE arguments as act's fields object: true or false ticks or unticks a checkbox; any
    other value is text, typed into a field or picked from a pop-up (a field to type "true" into needs act)."""
    out: dict = {}
    for item in items:
        k, sep, v = item.partition("=")
        if not sep or not k.strip():
            raise SystemExit(f"fill's fields are LABEL=VALUE, not {item!r}")
        out[k] = {"true": True, "false": False}.get(v.strip().lower(), v)
    return out


def save_as_arg(args: argparse.Namespace) -> str | dict | None:
    if not getattr(args, "save_as", None):
        if getattr(args, "var", None) or getattr(args, "describe", None):
            raise SystemExit("--var and --describe go with --save-as")
        return None
    spec: dict = {"name": args.save_as}
    if args.var:
        spec["vars"] = parse_vars(args.var)
    if args.describe:
        spec["description"] = args.describe
    return spec if len(spec) > 1 else args.save_as


def run_script(args: argparse.Namespace) -> int:
    """exec: run Python with `pu` (a Computer on the current session) and `Computer` defined."""
    import traceback

    from .api import ActionError, Computer, HelperError

    rest = list(args.args[1:]) if args.args[:1] == ["--"] else list(args.args)
    if args.code is not None:
        source, name = args.code, "<-c>"
        if args.file is not None:  # with -c there's no script file: that was its first argument
            rest.insert(0, args.file)
    elif args.file in (None, "-"):
        source, name = sys.stdin.read(), "<stdin>"
    else:
        source, name = Path(args.file).read_text(), args.file
    pu = Computer(window_arg(args.window))
    scope = {"pu": pu, "Computer": Computer, "ActionError": ActionError, "HelperError": HelperError,
             "__name__": "__main__", "__file__": name}
    sys.argv = [name, *rest]
    try:
        exec(compile(source, name, "exec"), scope)  # noqa: S102 - running the caller's own script is the point
        return 0
    except ActionError as e:
        print(f"stopped: {e}", file=sys.stderr)
        return 1
    except HelperError as e:  # a whole request refused (an unknown macro, a window that isn't there, …)
        print(f"error: {e}", file=sys.stderr)
        return 1
    except SystemExit as e:
        if e.code is None or isinstance(e.code, int):
            return e.code or 0
        print(e.code, file=sys.stderr)
        return 1
    except Exception:
        traceback.print_exc()
        return 1
    finally:
        pu.close()


def element_arg(v: str | None) -> dict:
    """-e 14 (or #14) is element 14; -e Save is the element showing "Save" (looked up when the action runs)."""
    if v is None:
        return {}
    v = element_number(v)
    return {"element": v} if isinstance(v, int) else {"element": int(v)} if v.strip().isdigit() else {"target": v}


def read_arg(v: str | bool) -> int | str | bool:
    """--read alone is the focused text; --read 12 (or #12) is element 12; --read Notes what shows "Notes"."""
    if v is True:
        return True
    v = element_number(v)
    return v if isinstance(v, int) else int(v) if v.strip().isdigit() else v


def find_args(texts: list[str]) -> dict:
    """find's texts: one is the query, several are looked for at once (at most 10); none, with --role,
    lists the elements of that role."""
    if len(texts) > 1:
        return {"queries": texts}
    return {"query": texts[0]} if texts else {}


def outline_args(args: argparse.Namespace, force: bool = False) -> dict:
    text = "interactive" if getattr(args, "interactive", False) else args.text or force
    return outline_params(text, getattr(args, "marks", False))


def act_args(args: argparse.Namespace) -> dict:
    """act's params for how it observes the window: --screenshot, --settle-ms, --no-guard, and the opt-in
    --crop-changes and --detail low (each left to its environment setting when not given)."""
    return act_params(args.screenshot, args.settle_ms, not args.no_guard, args.crop_changes or None, args.detail)


def build_action(args: argparse.Namespace) -> dict:
    cmd = args.cmd
    if cmd == "click":
        kind = "double_click" if args.double else "triple_click" if args.triple else "click"
        a: dict = {"type": kind}
        if args.right or args.middle:
            a["button"] = "right" if args.right else "middle"
        if args.mods:
            a["keys"] = args.mods.split("+")
        if args.item:
            a["item"] = args.item
    elif cmd == "move":
        a = {"type": "move"}
    elif cmd == "type":
        a = {"type": "type", "text": args.content}
        if args.clear:
            a["clear"] = True
        if args.submit:
            a["submit"] = True
    elif cmd == "key":
        a = {"type": "keypress", "keys": args.combo}
        if args.repeat is not None and args.repeat != 1:
            a["repeat"] = args.repeat  # out of 1-100 the helper says so
        return a
    elif cmd == "menu":
        return {"type": "menu", "item": args.item}
    elif cmd == "select":
        return {"type": "select", **element_arg(args.element), "option": args.option}
    elif cmd == "fill":
        a = {"type": "fill", "fields": parse_fields(args.fields)}
        if args.submit is True:  # --submit alone: Return
            a["submit"] = True
        elif args.submit is not None:  # the button's number, or the text it shows
            aim = element_arg(args.submit)
            a["submit"] = aim.get("element", aim.get("target"))
    elif cmd == "navigate":
        a = {"type": "navigate", "url": args.url}
        if args.new_window is not None:
            a["new_window"] = args.new_window
        return a
    elif cmd == "open":
        a = {"type": "open"}
        if args.target:
            a["url" if "://" in args.target or args.target.startswith("mailto:") else "path"] = args.target
        if args.app:
            a["app"] = args.app
        if len(a) == 1:
            raise SystemExit("open needs a URL, a file path, or --app")
        return a
    elif cmd == "wait-for":
        if (args.content is None) != args.change:
            raise SystemExit("wait-for needs TEXT, or --change (not both)")
        a = {"type": "wait_for", "change": True} if args.change else {"type": "wait_for", "text": args.content}
        if args.role:
            a["role"] = args.role
        if args.gone:
            a["gone"] = True
        if args.timeout_ms is not None:
            a["timeout_ms"] = args.timeout_ms
        return a
    elif cmd == "scroll":
        if args.until is None:
            if args.role or args.max_scrolls is not None:
                raise SystemExit("--role and --max-scrolls go with --until")
            if not args.dy and not args.dx:
                raise SystemExit("scroll needs --dy and/or --dx (pixels, positive = down/right), or --until TEXT")
            a = {"type": "scroll", "scroll_y": args.dy, "scroll_x": args.dx}
        else:  # a screenful at a time unless --dy/--dx say how far
            a = {"type": "scroll", "until": {"text": args.until, "role": args.role} if args.role else args.until,
                 **{k: v for k, v in (("scroll_y", args.dy), ("scroll_x", args.dx)) if v}}
            if args.max_scrolls is not None:
                a["max_scrolls"] = args.max_scrolls
    elif cmd == "drag":
        nums = [int(float(v)) for v in args.points]
        if len(nums) < 4 or len(nums) % 2:
            raise SystemExit("drag needs pairs: X1 Y1 X2 Y2 [X3 Y3 ...]")
        return {"type": "drag", "path": [nums[i : i + 2] for i in range(0, len(nums), 2)]}
    elif cmd == "set":
        return {"type": "set_value", **element_arg(args.element), "text": args.content}
    elif cmd == "perform":
        return {"type": "perform", **element_arg(args.element), "name": args.name,
                **({"confirm": True} if args.confirm else {})}
    elif cmd == "wait":
        return {"type": "wait", "ms": args.ms}
    elif cmd == "macro":  # --confirm: the user OK'd the presses this replay makes
        return {"type": "macro", "name": args.name, **({"vars": parse_vars(args.vars)} if args.vars else {}),
                **({"confirm": True} if args.confirm else {})}
    elif cmd == "activate":
        return {"type": "activate"}
    else:
        raise SystemExit(f"unknown command {cmd}")
    if getattr(args, "confirm", False):
        a["confirm"] = True
    if getattr(args, "element", None) is not None:
        a.update(element_arg(args.element))
    elif getattr(args, "x", None) is not None:
        a["x"], a["y"] = args.x, args.y
    elif getattr(args, "at", None):
        a["x"], a["y"] = args.at
    return a


async def run(args: argparse.Namespace) -> int:
    # One request per process: it can't report later whether the reply reached anyone, so the helper
    # counts a reply it wrote as delivered.
    h = Helper(session("default"), reports=False)
    try:
        if args.cmd == "setup":
            print(f"helper: {app_path()}")
            res = await h.call("permissions")
            for k, v in res.items():
                print(f"{k}: {'granted' if v else 'NOT granted'}")
            if not all(res.values()):
                print("Grant PuterUse in System Settings > Privacy & Security > Accessibility and > Screen &\n"
                      "System Audio Recording, then run `puter-use quit` and `puter-use setup` again.")
                return 1
            print("ready")
        elif args.cmd == "status":
            print(json.dumps(await h.call("status"), indent=1))
        elif args.cmd == "windows":
            print(window_list(await h.call("windows", app=args.app, launch=args.launch or None,
                                           window_size=capture_params()["window_size"]),
                              hidden_cap=None if args.app else HIDDEN_CAP))
        elif args.cmd in ("shot", "screenshot") and args.read is not None:
            return report(await h.call("screenshot", window=window_arg(args.window or args.window_pos),
                                       read=read_arg(args.read), offset=args.offset, limit=args.limit,
                                       query=args.query))
        elif args.cmd in ("shot", "screenshot"):
            if args.offset is not None or args.limit is not None or args.query is not None:
                raise SystemExit("--offset, --limit and --query go with --read")
            return report(await h.call("screenshot", window=window_arg(args.window or args.window_pos),
                                       region=parse_region(args.region), image=False if args.no_image else None,
                                       **outline_args(args, args.no_image), **capture_params(),
                                       **detail_param(args.detail)))
        elif args.cmd == "find":
            print(summarize(await h.call("find", window=window_arg(args.window), **find_args(args.query),
                                         role=args.role, limit=args.limit, **capture_params())))
        elif args.cmd == "macros":
            print(summarize(await h.call("macros", window=window_arg(args.window), all=args.all or None,
                                         delete=args.delete)))
        elif args.cmd == "menus":
            res = await h.call("menus", window=window_arg(args.window), query=args.query)
            print(summarize(res))
        elif args.cmd == "act":
            try:
                actions = json.loads(args.json)
            except json.JSONDecodeError as e:
                print(f"error: actions aren't valid JSON ({e})", file=sys.stderr)
                return 2
            if isinstance(actions, dict):
                actions = [actions]
            actions = [element_numbers(a) for a in actions] if isinstance(actions, list) else actions
            if args.confirm:
                print('error: in act, put "confirm": true on the action the user OK\'d', file=sys.stderr)
                return 2
            return report(await h.call("act", window=window_arg(args.window), actions=actions,
                                       foreground=args.fg or None, save_as=save_as_arg(args), **outline_args(args),
                                       **act_args(args),
                                       **capture_params()))
        elif args.cmd == "release":
            await h.call("release", autostart=False)
        elif args.cmd == "quit":
            await h.quit()
        else:
            return report(await h.call("act", window=window_arg(args.window), actions=[build_action(args)],
                                       foreground=args.fg or None, **outline_args(args),
                                       **act_args(args),
                                       **capture_params()), missed=getattr(args, "until", None) is not None)
        return 0
    except HelperError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    finally:
        await h.close()


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="puter-use", description="Background computer use for macOS apps.")
    sub = p.add_subparsers(dest="cmd", required=True)

    def target(sp: argparse.ArgumentParser) -> argparse.ArgumentParser:
        sp.add_argument("-w", "--window", help="window id, app name, or 'screen' (default: last used)")
        sp.add_argument("--text", action="store_true",
                        help="include the numbered accessibility outline (just its changes once you've had it)")
        sp.add_argument("--interactive", action="store_true", help="--text, listing only what can be acted on")
        sp.add_argument("--marks", action="store_true", help="number the controls on the image")
        sp.add_argument("--fg", action="store_true", help="foreground fallback: raise the app, use the real cursor")
        sp.add_argument("--screenshot", choices=["auto", "always", "never"], default="auto",
                        help="after acting: image only if the window changed (auto), always, or never")
        sp.add_argument("--settle-ms", type=int, help="check for changes at least this long after the last input (default 250)")
        sp.add_argument("--no-guard", action="store_true",
                        help="don't stop before coordinate actions when something opened over the window")
        sp.add_argument("--crop-changes", action="store_true",
                        help="when little changed, the image shows only that part (default: PUTER_USE_CROP_CHANGES)")
        sp.add_argument("--detail", choices=["low"],
                        help="low: a sparser image that keeps text readable (default: PUTER_USE_DETAIL)")
        sp.add_argument("--confirm", action="store_true",
                        help="the user has OK'd this press (Delete, Send, Pay, … stop to ask otherwise)")
        return sp

    sub.add_parser("mcp", help="run the MCP server (stdio)")
    sub.add_parser("setup", help="start the helper and request macOS permissions")
    sub.add_parser("status")
    sub.add_parser("release", help="hide the agent cursor and forget the current window")
    sub.add_parser("quit", help="stop the helper app (returns once it has exited)")
    sp = sub.add_parser("windows", help="list controllable windows")
    sp.add_argument("app", nargs="?")
    sp.add_argument("--launch", action="store_true", help="open the app in the background if needed")
    sp = sub.add_parser("shot", aliases=["screenshot"], help="capture a window")
    sp.add_argument("window_pos", nargs="?", metavar="window")
    sp.add_argument("-w", "--window", help="window id, app name, or 'screen' (default: last used)")
    sp.add_argument("--region", help="zoom: x0,y0,x1,y1 in the last full screenshot's pixels")
    sp.add_argument("--text", action="store_true", help="add the numbered accessibility outline")
    sp.add_argument("--interactive", action="store_true", help="--text, listing only what can be acted on")
    sp.add_argument("--marks", action="store_true", help="number the controls on the image (as in the outline)")
    sp.add_argument("--detail", choices=["low"], help="low: a sparser image that keeps text readable")
    sp.add_argument("--no-image", action="store_true",
                    help="accessibility outline only (with --region: just the text in that area)")
    sp.add_argument("--read", nargs="?", const=True, metavar="ELEMENT",
                    help="instead of an image, the whole text of a text area or field, scrolled-out parts too: its "
                         "number or the text it shows (alone: the focused one)")
    sp.add_argument("--offset", type=int,
                    help="with --read: start at this character (default 0; below 0, that many from the end)")
    sp.add_argument("--limit", type=int, help="with --read: this many characters (default 10000, at most 50000)")
    sp.add_argument("--query", help="with --read: where this text is in it instead (case-insensitive), a line per "
                                    "match with its offset")
    sp = sub.add_parser("find", help="find elements by the text they show; prints their numbers")
    sp.add_argument("query", nargs="*", metavar="text",
                    help="what it shows; several (up to 10) are looked for at once; none with --role lists that role")
    sp.add_argument("--role", help="e.g. button, field, checkbox, link")
    sp.add_argument("--limit", type=int)
    sp.add_argument("-w", "--window", help="window id, app name, or 'screen' (default: last used)")
    sp = target(sub.add_parser("act", help="run a JSON list of actions"))
    sp.add_argument("json")
    sp.add_argument("--save-as", metavar="NAME", help="if every action succeeds, save the batch as a macro")
    sp.add_argument("--var", action="append", metavar="NAME=VALUE",
                    help="with --save-as: VALUE (as used in this batch) becomes a variable to fill on replay")
    sp.add_argument("--describe", help="with --save-as: what the macro does")
    sp = target(sub.add_parser("macro", help="replay a saved macro: macro NAME [VAR=VALUE ...]"))
    sp.add_argument("name")
    sp.add_argument("vars", nargs="*", metavar="VAR=VALUE")
    sp = sub.add_parser("macros", help="list the macros saved for the window's app")
    sp.add_argument("-w", "--window", help="window id, app name, or 'screen' (default: last used)")
    sp.add_argument("--all", action="store_true", help="every app's macros")
    sp.add_argument("--delete", metavar="NAME")
    sp = sub.add_parser("exec", help="run a Python script with `pu` (a puter_use.api.Computer) ready")
    sp.add_argument("file", nargs="?", help="script path, or - for stdin")
    sp.add_argument("-c", dest="code", help="the script as a string")
    sp.add_argument("-w", "--window", help="window to start on (pu.window)")
    sp.add_argument("args", nargs=argparse.REMAINDER, help="sys.argv[1:] for the script")
    sp = target(sub.add_parser("click"))
    sp.add_argument("x", type=float, nargs="?")
    sp.add_argument("y", type=float, nargs="?")
    sp.add_argument("-e", "--element", help="an element's number, or the text it shows")
    buttons = sp.add_mutually_exclusive_group()
    buttons.add_argument("--right", action="store_true")
    buttons.add_argument("--middle", action="store_true")
    sp.add_argument("--double", action="store_true")
    sp.add_argument("--triple", action="store_true")
    sp.add_argument("--mods", help="held modifiers, e.g. cmd or cmd+shift")
    sp.add_argument("--item", help='choose this in the menu the click opens, e.g. "Font > Bold"')
    sp = target(sub.add_parser("move"))
    sp.add_argument("x", type=float)
    sp.add_argument("y", type=float)
    sp = target(sub.add_parser("type", help="type text (into the focused field, or click one first)"))
    sp.add_argument("content", metavar="text")
    sp.add_argument("-e", "--element", help="click this element first (its number, or the text it shows)")
    sp.add_argument("--at", nargs=2, type=float, metavar=("X", "Y"), help="click here first")
    sp.add_argument("--clear", action="store_true", help="empty the field first")
    sp.add_argument("--submit", action="store_true", help="press Return after")
    sp = target(sub.add_parser("key", help="press a key, a shortcut, or a sequence"))
    sp.add_argument("combo", help="e.g. cmd+t, Return, ctrl+shift+Tab, or a sequence: 'Tab Tab Return'")
    sp.add_argument("--repeat", type=int, help="press it (or the sequence) this many times (1-100)")
    sp = sub.add_parser("menus", help="list the app's menu commands and their shortcuts")
    sp.add_argument("query", nargs="?", help="only items matching this")
    sp.add_argument("-w", "--window", help="window id, app name, or 'screen' (default: last used)")
    sp = target(sub.add_parser("menu", help="run a menu command: 'File > Export as PDF…', or its name alone if unique"))
    sp.add_argument("item")
    sp = target(sub.add_parser("select", help="pick an option of a pop-up or combo box"))
    sp.add_argument("element", help="its number, or the text it shows")
    sp.add_argument("option")
    sp = target(sub.add_parser("fill", help="fill in a form by its labels: fill Email=ada@example.com 'I agree=true'"))
    sp.add_argument("fields", nargs="+", metavar="LABEL=VALUE",
                    help="true/false ticks or unticks a checkbox; other text is typed, or picked from a pop-up")
    sp.add_argument("--submit", nargs="?", const=True, metavar="BUTTON",
                    help="then press Return (alone), or the button showing BUTTON (or element number)")
    sp = target(sub.add_parser("navigate", help="go to a URL in a browser (in the agent's own window)"))
    sp.add_argument("url")
    nw = sp.add_mutually_exclusive_group()
    nw.add_argument("--new-window", dest="new_window", action="store_true", default=None)
    nw.add_argument("--same-window", dest="new_window", action="store_false")
    sp = target(sub.add_parser("open", help="open a link, document or app in the background"))
    sp.add_argument("target", nargs="?", help="URL or file path")
    sp.add_argument("--app", help="the app to open it with (or to launch)")
    sp = target(sub.add_parser("wait-for", help="wait until an element showing TEXT appears (or the window changes)"))
    sp.add_argument("content", metavar="text", nargs="?")
    sp.add_argument("--role", help="e.g. button, field, text")
    sp.add_argument("--gone", action="store_true", help="wait until it goes away instead")
    sp.add_argument("--change", action="store_true",
                    help="instead of TEXT: until the window looks different from when this call began, then settles")
    sp.add_argument("--timeout-ms", type=int)
    sp = target(sub.add_parser("scroll"))
    sp.add_argument("x", type=float, nargs="?")
    sp.add_argument("y", type=float, nargs="?")
    sp.add_argument("--dy", type=int, default=0, help="pixels, positive = down")
    sp.add_argument("--dx", type=int, default=0, help="pixels, positive = right")
    sp.add_argument("--until", metavar="TEXT",
                    help="scroll (a screenful at a time, or --dy/--dx) until an element showing TEXT is in view")
    sp.add_argument("--role", help="with --until: of this role (button, link, …)")
    sp.add_argument("--max-scrolls", type=int, help="with --until: scroll at most this many times (default 10, up to 15)")
    sp = target(sub.add_parser("drag"))
    sp.add_argument("points", nargs="+")
    sp = target(sub.add_parser("set", help="set an element's value"))
    sp.add_argument("element", help="its number, or the text it shows")
    sp.add_argument("content", metavar="text")
    sp = target(sub.add_parser("perform", help="run an accessibility action on an element"))
    sp.add_argument("element", help="its number, or the text it shows")
    sp.add_argument("name", help="expand, collapse, increment, decrement, showmenu, scroll_to_visible, …")
    sp = target(sub.add_parser("wait"))
    sp.add_argument("ms", type=int)
    target(sub.add_parser("activate", help="bring the window to the front"))
    return p


def stoppable(command) -> int:
    """Run a CLI command so that Ctrl-C (SIGINT) stops it with one line and exit status 130, no traceback.
    The helper's request is cancelled on the way out: the connection closes, which the helper takes as a
    cancel (nothing more is pressed or typed; held keys and buttons are let go). SIGINT stops it even when
    it was ignored as the CLI started (a script's background job, which Ctrl-C reaches too): stopping
    puter-use is what Ctrl-C is for."""
    signal.signal(signal.SIGINT, signal.default_int_handler)  # asyncio.run then cancels the request on SIGINT
    try:
        return command()
    except KeyboardInterrupt:
        signal.signal(signal.SIGINT, signal.SIG_IGN)  # it's stopping: another Ctrl-C needn't interrupt that
        print("stopped: interrupted", file=sys.stderr)
        return 130


def main() -> None:
    args = parser().parse_args()
    if args.cmd == "mcp":
        from .mcp_server import main as mcp_main

        mcp_main()
        return
    if args.cmd == "screenshot":
        args.cmd = "shot"
    if args.cmd == "exec":
        sys.exit(stoppable(lambda: run_script(args)))
    sys.exit(stoppable(lambda: asyncio.run(run(args))))
