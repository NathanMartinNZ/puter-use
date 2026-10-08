"""puter-use CLI: the same windows/screenshot/act loop for harnesses that drive tools via shell.

Screenshots are written to files (path printed) so any agent that can view images can use them.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

from .client import Helper, HelperError, app_path
from .present import image_bytes, summarize, window_list
from .settings import act_params, capture_params, outline_params, session

SHOTS = Path(os.environ.get("PUTER_USE_SHOTS") or Path.home() / "Library/Caches/puter-use/shots")


def save_image(res: dict) -> str | None:
    img = image_bytes(res)
    if not img:
        return None
    SHOTS.mkdir(parents=True, exist_ok=True)
    ext = {"image/png": "png", "image/webp": "webp"}.get(img[1], "jpg")
    path = SHOTS / f"{time.strftime('%H%M%S')}-{time.monotonic_ns() % 10**6:06d}.{ext}"
    path.write_bytes(img[0])
    for old in sorted(SHOTS.iterdir(), key=lambda p: p.stat().st_mtime)[:-40]:
        old.unlink(missing_ok=True)
    return str(path)


def report(res: dict) -> int:
    """Print the result; the exit status is 1 if an action failed or the batch stopped early."""
    print(summarize(res))
    path = save_image(res)
    if path:
        print(f"image: {path}")
    return 1 if res.get("errors") or res.get("stopped") else 0


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
    """-e 14 is element 14; -e Save is the element showing "Save" (looked up when the action runs)."""
    if v is None:
        return {}
    return {"element": int(v)} if v.strip().isdigit() else {"target": v}


def outline_args(args: argparse.Namespace, force: bool = False) -> dict:
    text = "interactive" if getattr(args, "interactive", False) else args.text or force
    return outline_params(text, getattr(args, "marks", False))


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
        a = {"type": "wait_for", "text": args.content}
        if args.role:
            a["role"] = args.role
        if args.gone:
            a["gone"] = True
        if args.timeout_ms is not None:
            a["timeout_ms"] = args.timeout_ms
        return a
    elif cmd == "scroll":
        a = {"type": "scroll", "scroll_y": args.dy, "scroll_x": args.dx}
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
    h = Helper(session("default"))
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
                                           window_size=capture_params()["window_size"])))
        elif args.cmd in ("shot", "screenshot"):
            return report(await h.call("screenshot", window=window_arg(args.window or args.window_pos),
                                       region=parse_region(args.region), image=False if args.no_image else None,
                                       **outline_args(args, args.no_image), **capture_params()))
        elif args.cmd == "find":
            print(summarize(await h.call("find", window=window_arg(args.window), query=args.query, role=args.role,
                                         limit=args.limit, **capture_params())))
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
            if args.confirm:
                print('error: in act, put "confirm": true on the action the user OK\'d', file=sys.stderr)
                return 2
            return report(await h.call("act", window=window_arg(args.window), actions=actions,
                                       foreground=args.fg or None, save_as=save_as_arg(args), **outline_args(args),
                                       **act_params(args.screenshot, args.settle_ms, not args.no_guard),
                                       **capture_params()))
        elif args.cmd == "release":
            await h.call("release", autostart=False)
        elif args.cmd == "quit":
            try:
                await h.call("quit", autostart=False)
            except HelperError:
                pass
        else:
            return report(await h.call("act", window=window_arg(args.window), actions=[build_action(args)],
                                       foreground=args.fg or None, **outline_args(args),
                                       **act_params(args.screenshot, args.settle_ms, not args.no_guard),
                                       **capture_params()))
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
        sp.add_argument("--settle-ms", type=int, help="pause before checking for changes (default 250)")
        sp.add_argument("--no-guard", action="store_true",
                        help="don't stop before coordinate actions when something opened over the window")
        sp.add_argument("--confirm", action="store_true",
                        help="the user has OK'd this press (Delete, Send, Pay, … stop to ask otherwise)")
        return sp

    sub.add_parser("mcp", help="run the MCP server (stdio)")
    sub.add_parser("setup", help="start the helper and request macOS permissions")
    sub.add_parser("status")
    sub.add_parser("release", help="hide the agent cursor and forget the current window")
    sub.add_parser("quit", help="stop the helper app")
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
    sp.add_argument("--no-image", action="store_true",
                    help="accessibility outline only (with --region: just the text in that area)")
    sp = sub.add_parser("find", help="find elements by the text they show; prints their numbers")
    sp.add_argument("query")
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
    sp = target(sub.add_parser("menu", help="run a menu command, e.g. 'File > Export as PDF…'"))
    sp.add_argument("item")
    sp = target(sub.add_parser("select", help="pick an option of a pop-up or combo box"))
    sp.add_argument("element", help="its number, or the text it shows")
    sp.add_argument("option")
    sp = target(sub.add_parser("navigate", help="go to a URL in a browser (in the agent's own window)"))
    sp.add_argument("url")
    nw = sp.add_mutually_exclusive_group()
    nw.add_argument("--new-window", dest="new_window", action="store_true", default=None)
    nw.add_argument("--same-window", dest="new_window", action="store_false")
    sp = target(sub.add_parser("open", help="open a link, document or app in the background"))
    sp.add_argument("target", nargs="?", help="URL or file path")
    sp.add_argument("--app", help="the app to open it with (or to launch)")
    sp = target(sub.add_parser("wait-for", help="wait until an element showing TEXT appears"))
    sp.add_argument("content", metavar="text")
    sp.add_argument("--role", help="e.g. button, field, text")
    sp.add_argument("--gone", action="store_true", help="wait until it goes away instead")
    sp.add_argument("--timeout-ms", type=int)
    sp = target(sub.add_parser("scroll"))
    sp.add_argument("x", type=float, nargs="?")
    sp.add_argument("y", type=float, nargs="?")
    sp.add_argument("--dy", type=int, default=0, help="pixels, positive = down")
    sp.add_argument("--dx", type=int, default=0, help="pixels, positive = right")
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


def main() -> None:
    args = parser().parse_args()
    if args.cmd == "mcp":
        from .mcp_server import main as mcp_main

        mcp_main()
        return
    if args.cmd == "screenshot":
        args.cmd = "shot"
    if args.cmd == "exec":
        sys.exit(run_script(args))
    sys.exit(asyncio.run(run(args)))
