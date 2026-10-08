#!/usr/bin/env python3
"""Check that puter-use's input is human-like and that the app receives exactly what's drawn.

Inputs: the helper's trace (run actions with PUTER_USE_TRACE=<file>) and, optionally, the log of
PuterUseProbe (scripts/probe.sh), the test window that records every event it receives.

    scripts/check_motion.py --trace trace.jsonl --probe ~/Library/Caches/puter-use/probe.jsonl

Checks:
  drawn = sent      every drawn pointer frame was sent to the app at the same point and moment
  received = sent   the probe got every pointer and key event that was sent to it, in order
  path              each move is a gentle curve (not a straight line), takes the Fitts's-law time,
                    speeds up then slows down (bell-shaped), overshoots a little on long moves and
                    ends exactly on target; drags follow their points with the same speed profile
  click on arrival  buttons go down only where the pointer arrived, after it arrived, held like a finger
  typing            keys come at about the configured WPM with a human spread (not a metronome),
                    are held for varying times, roll over at speed, and capitals are typed with Shift
Exit status 1 if any check fails.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

POINTER = {"move", "drag", "rdrag", "mdrag"}
BUTTONS = {"down", "up", "rdown", "rup", "mdown", "mup"}
KEYS = {"keydown", "keyup", "flags"}
SHIFT_MASK = 0x20000
MODIFIER_CODES = {0x37, 0x38, 0x3A, 0x3B, 0x3F, 0x36, 0x3C, 0x3D, 0x3E}


def load(path: str | None) -> list[dict]:
    if not path:
        return []
    return [json.loads(line) for line in Path(path).expanduser().read_text().splitlines() if line.strip()]


def fitts(d: float) -> float:
    return min(0.85, max(0.14, 0.11 + 0.09 * math.log2(1 + d / 14)))


class Report:
    def __init__(self) -> None:
        self.rows: list[tuple[str, bool | None, str]] = []

    def check(self, name: str, ok: bool | None, detail: str) -> None:
        """ok=None: skipped (not applicable to this run)."""
        self.rows.append((name, ok, detail))

    def print(self) -> bool:
        width = max((len(r[0]) for r in self.rows), default=10)
        for name, ok, detail in self.rows:
            print(f"{'SKIP' if ok is None else 'PASS' if ok else 'FAIL'}  {name.ljust(width)}  {detail}")
        return all(ok is not False for _, ok, _ in self.rows)


def drawn_vs_sent(trace: list[dict], rep: Report) -> None:
    """Each pointer frame is logged just before the event made from it. A frame within 0.25 pt of the
    last point sent may be skipped; any other frame must be sent, at the same point and within one
    display frame (a busy main thread can hold the event a few ms after the frame is logged)."""
    last_sent = last_frame = None
    pending = None  # a drawn frame that must be sent before the next one
    sent = mismatched = unsent = 0
    for r in trace:
        if r["k"] == "pointer":
            if pending is not None:
                unsent += 1
            pending = r if last_sent is None or math.dist(last_sent, (r["x"], r["y"])) >= 0.25 else None
            last_frame = r
        elif r["k"] == "event" and r["type"] in POINTER and r.get("label") != "primer":
            sent += 1
            f = pending or last_frame
            # A move that repeats the point already sent (a click re-asserting where it is) needs no frame.
            repeat = pending is None and last_sent is not None and math.dist(last_sent, (r["x"], r["y"])) < 1e-6
            if not repeat and (f is None or math.dist((f["x"], f["y"]), (r["x"], r["y"])) > 1e-6
                               or abs(r["t"] - f["t"]) > 1 / 60):
                mismatched += 1
            last_sent = (r["x"], r["y"])
            pending = None
    if pending is not None:
        unsent += 1
    if sent == 0:
        frames = sum(r["k"] == "pointer" for r in trace)
        rep.check("drawn = sent", False if frames else None,
                  f"{frames} drawn frames but no pointer events sent" if frames else "no pointer motion in this trace")
        return
    rep.check("drawn = sent", mismatched == 0 and unsent == 0,
              f"{sent} pointer events; {mismatched} differ from the drawn frame; {unsent} drawn frames not sent")


def received_vs_sent(trace: list[dict], probe: list[dict], rep: Report) -> None:
    start = next((r for r in probe if r["k"] == "start"), None)
    if not start:
        return
    pid = start["pid"]
    frames = [(r["t"], r["frame"]) for r in probe if r["k"] in ("start", "frame") and r.get("window") == start["window"]]

    def frame_at(t: float) -> list[float]:
        f = frames[0][1]
        for ft, fr in frames:
            if ft <= t:
                f = fr
        return f

    t0 = start["t"]
    sent = [r for r in trace if r["k"] == "event" and r.get("pid") == pid and r["t"] >= t0
            and r["type"] in POINTER | BUTTONS | KEYS]
    # While a menu is open it takes what's sent (from just after the click that opened it): the window,
    # and so the probe, never sees those events.
    spans = []
    for i, r in enumerate(trace):
        if r["k"] == "menu" and r.get("open"):
            downs = [e["t"] for e in trace[:i] if e["k"] == "event" and e["type"] in ("down", "rdown", "mdown")
                     and r["t"] - e["t"] < 1.5]
            end = next((e["t"] for e in trace[i:] if e["k"] == "menu" and not e.get("open")), math.inf)
            spans.append((downs[-1] if downs else r["t"], end))
    in_menu = [r for r in sent if any(a < r["t"] <= b for a, b in spans)]
    sent = [r for r in sent if not any(a < r["t"] <= b for a, b in spans)]
    got = [r for r in probe if r["k"] == "event" and r["type"] in POINTER | BUTTONS | KEYS]
    # Only what arrived while this trace was being sent counts as "other" events.
    span = (sent[0]["t"] - 0.5, sent[-1]["t"] + 0.5) if sent else (0, 0)
    during = sum(span[0] <= g["t"] <= span[1] for g in got)
    if not sent:
        rep.check("received = sent", None, f"nothing was sent to the probe (pid {pid}) in this trace")
        return
    j = 0
    missing: list[dict] = []
    worst = 0.0
    latencies = []
    for s in sent:
        k = j
        while k < len(got) and got[k]["t"] <= s["t"] + 0.25:
            g = got[k]
            if g["type"] == s["type"] and g["t"] >= s["t"] - 0.05:
                if s["type"] in KEYS:
                    # Control characters differ in spelling (BackSpace goes out as \x08, AppKit reports \x7f).
                    printable = all(c.isprintable() for c in (s.get("chars") or "") + (g.get("chars") or ""))
                    same_chars = not printable or not s.get("chars") or not g.get("chars") or s["chars"] == g["chars"]
                    if g.get("code") == s.get("code") and same_chars:
                        break
                else:
                    fx, fy = frame_at(s["t"])[:2]
                    err = math.dist((s["x"] - fx, s["y"] - fy), (g["x"], g["y"]))
                    if err <= 1.0:
                        worst = max(worst, err)
                        break
            k += 1
        if k == len(got) or got[k]["t"] > s["t"] + 0.25:
            missing.append(s)
        else:
            latencies.append(got[k]["t"] - s["t"])
            j = k + 1
    extra = during - (len(sent) - len(missing))
    drags_only = missing and all(m["type"] in ("drag", "rdrag", "mdrag", "up") for m in missing)
    lat = f"median delivery {statistics.median(latencies) * 1000:.1f} ms" if latencies else ""
    rep.check("received = sent", not missing,
              f"{len(sent) - len(missing)}/{len(sent)} sent events arrived in order (worst position error "
              f"{worst:.2f} pt, {lat}); {len(missing)} missing"
              + (f", first missing: {missing[0]['type']} at t={missing[0]['t']:.3f}" if missing else "")
              + (" (drags into an AppKit text view are taken by its own tracking and never logged)" if drags_only else "")
              + (f"; {extra} other events (e.g. your real mouse passing over the window)" if extra > 0 else "")
              + (f"; {len(in_menu)} went into an open menu (it tracks them itself)" if in_menu else ""))


def paths(trace: list[dict], rep: Report, speed: float) -> None:
    plans = {r["id"]: r for r in trace if r["k"] == "plan"}
    samples: dict[int, list[dict]] = {}
    for r in trace:
        if r["k"] == "pointer" and r["id"] in plans:
            samples.setdefault(r["id"], []).append(r)
    problems: list[str] = []
    reaches = strokes = holds = overshoots = 0
    curvatures = []
    for pid, plan in plans.items():
        pts = samples.get(pid, [])
        if len(pts) < 3:
            continue
        a, b = plan["from"], plan["to"]
        d = math.dist(a, b)
        end = (pts[-1]["x"], pts[-1]["y"])
        if math.dist(end, b) > 0.01:
            problems.append(f"#{pid} ends at {end}, not {b}")
        elapsed = pts[-1]["t"] - plan["t"]
        # A hold may be cut short: it keeps a held button company until the keys pressed meanwhile are done.
        cut_short = plan.get("kind") == "hold" and elapsed < plan["duration"]
        if not cut_short and abs(elapsed - plan["duration"]) > 0.15 * plan["duration"] + 0.02:
            problems.append(f"#{pid} took {elapsed:.3f}s, planned {plan['duration']:.3f}s")
        rate = len(pts) / max(elapsed, 1e-6)
        if rate < 50:
            problems.append(f"#{pid} only {rate:.0f} frames/s")
        speeds = []
        for p, q in zip(pts, pts[1:]):
            dt = q["t"] - p["t"]
            if dt > 0:
                speeds.append(((p["t"] + q["t"]) / 2 - plan["t"], math.dist((p["x"], p["y"]), (q["x"], q["y"])) / dt))
        if plan["kind"] == "hold":  # a still hand with the button down: a faint tremor on the spot
            holds += 1
            worst = max(math.dist((p["x"], p["y"]), plan["point"]) for p in pts)
            if worst > 1:
                problems.append(f"#{pid} hold wanders {worst:.1f} pt")
            continue
        if plan["kind"] == "reach":
            reaches += 1
            if d < 30:
                continue
            want = fitts(d) / speed
            if not want - 0.005 <= plan["duration"] <= want + 0.05:
                problems.append(f"#{pid} planned {plan['duration']:.3f}s for {d:.0f} pt; Fitts says {want:.3f}s")
            ux, uy = (b[0] - a[0]) / d, (b[1] - a[1]) / d
            dev = max(abs((p["x"] - a[0]) * uy - (p["y"] - a[1]) * ux) for p in pts)
            curvatures.append(dev / d)
            low = 0 if plan.get("lane") else min(0.008, 0.2 * 140 / d)  # a lane (a menu row) may be straight
            if not low <= dev / d <= 0.15:
                problems.append(f"#{pid} bends {dev / d:.1%} of its {d:.0f} pt (want a gentle curve)")
            primary = plan.get("primary", plan["duration"])
            main = [s for s in speeds if s[0] <= primary]
            if len(main) >= 8:
                peak_t, peak = max(main, key=lambda s: s[1])
                edge = [s[1] for s in main if s[0] < 0.08 * primary or s[0] > 0.92 * primary]
                if not 0.2 * primary <= peak_t <= 0.7 * primary:
                    problems.append(f"#{pid} peak speed at {peak_t / primary:.0%} of the move (want the middle)")
                if edge and max(edge) > 0.5 * peak:
                    problems.append(f"#{pid} starts/ends at {max(edge) / peak:.0%} of peak speed (want slow)")
            beyond = max(((p["x"] - a[0]) * ux + (p["y"] - a[1]) * uy) - d for p in pts)
            if plan.get("overshoot", 0) > 0:
                overshoots += 1
                if not 0.2 < beyond <= 13:
                    problems.append(f"#{pid} overshoots by {beyond:.1f} pt (want 0.2-13)")
            elif beyond > 0.5:
                problems.append(f"#{pid} overshoots by {beyond:.1f} pt without planning to")
        else:
            strokes += 1
            line = plan["points"]

            def off(p: dict) -> float:
                best = float("inf")
                for (x0, y0), (x1, y1) in zip(line, line[1:]):
                    vx, vy = x1 - x0, y1 - y0
                    L = vx * vx + vy * vy
                    t = 0 if L == 0 else max(0, min(1, ((p["x"] - x0) * vx + (p["y"] - y0) * vy) / L))
                    best = min(best, math.dist((p["x"], p["y"]), (x0 + t * vx, y0 + t * vy)))
                return best

            worst = max(off(p) for p in pts)
            if worst > 0.5:
                problems.append(f"#{pid} drag strays {worst:.1f} pt from its path")
            # Each leg (split at sharp corners) has its own bell: fastest mid-leg, slow at its ends.
            for start, dur in plan.get("legs") or [[0, plan["duration"]]]:
                leg = [(t - start, v) for t, v in speeds if start <= t <= start + dur]
                if len(leg) >= 8:
                    peak_t, peak = max(leg, key=lambda s: s[1])
                    if not 0.2 * dur <= peak_t <= 0.75 * dur:
                        problems.append(f"#{pid} drag leg peaks at {peak_t / dur:.0%} of it (want the middle)")
    if reaches + strokes + holds == 0:
        if speed <= 0:
            rep.check("path", None, "speed 0: the pointer jumps, so there are no paths to judge")
        else:
            rep.check("path", None, "no pointer motion in this trace")
        return
    curv = f", bends {min(curvatures):.1%}-{max(curvatures):.1%}" if curvatures else ""
    held = f", {holds} still holds" if holds else ""
    rep.check("path", not problems, f"{reaches} moves ({overshoots} with overshoot), {strokes} drags{held}{curv}"
              + ("; " + "; ".join(problems[:6]) if problems else ""))


def clicks(trace: list[dict], rep: Report, instant: bool) -> None:
    """Buttons go down where the pointer is, once its motion has finished, and are held like a finger."""
    last_ptr: dict[int, dict] = {}
    frames: dict[int, list[float]] = {}  # motion id -> its frame times
    order: list[int] = []
    downs: dict[tuple[int, str], dict] = {}
    problems, holds, aims = [], [], []
    n = 0
    for r in trace:
        if r["k"] == "pointer":
            if r["id"] not in frames:
                order.append(r["id"])
            frames.setdefault(r["id"], []).append(r["t"])
            continue
        if r["k"] != "event" or r.get("label") == "primer":
            continue
        if r["type"] in POINTER:
            last_ptr[r["pid"]] = r
            if r["type"] != "move":  # a drag, not a click: its hold isn't a finger's tap
                for d in downs.values():
                    d["drag"] = True
        elif r["type"] in ("down", "rdown", "mdown"):
            n += 1
            prev = last_ptr.get(r["pid"])
            if prev is None or math.dist((prev["x"], prev["y"]), (r["x"], r["y"])) > 0.5:
                problems.append(f"press at ({r['x']:.0f},{r['y']:.0f}) is not where the pointer is")
            started = [i for i in order if frames[i][0] < r["t"]]
            if started and frames[started[-1]][-1] > r["t"]:
                problems.append(f"press at t={r['t']:.3f} while the pointer was still moving")
            elif started and r["t"] - frames[started[-1]][-1] < 1.0:
                aims.append(r["t"] - frames[started[-1]][-1])  # from arriving to pressing
            downs[(r["pid"], r["type"])] = r
        elif r["type"] in ("up", "rup", "mup"):
            d = downs.pop((r["pid"], {"up": "down", "rup": "rdown", "mup": "mdown"}[r["type"]]), None)
            if d and not d.get("drag"):
                holds.append(r["t"] - d["t"])
    if n == 0:
        return
    if holds and not instant:
        bad = [h for h in holds if not 0.03 <= h <= 0.2]
        if bad:
            problems.append(f"{len(bad)} presses held {min(bad) * 1000:.0f}-{max(bad) * 1000:.0f} ms (want 30-200)")
    if aims and not instant and statistics.median(aims) < 0.03:
        problems.append(f"pressed {statistics.median(aims) * 1000:.0f} ms after arriving (median; want a human beat, 40+ ms)")
    hold = f", held {min(holds) * 1000:.0f}-{max(holds) * 1000:.0f} ms" if holds else ""
    hold += f", pressed {min(aims) * 1000:.0f}-{max(aims) * 1000:.0f} ms after arriving" if aims else ""
    rep.check("click on arrival", not problems, f"{n} presses{hold}" + ("; " + "; ".join(problems[:4]) if problems else ""))


def drag_flow(trace: list[dict], rep: Report) -> None:
    """While a drag holds the button, events keep coming: apps tracking a press (text selection, sliders)
    take a pause in drags with the real button up as the press being over."""
    gaps, n = [], 0
    held: dict[int, float] = {}  # pid -> time of the last event while the button is down
    dragged: set[int] = set()
    for r in trace:
        if r["k"] != "event" or r.get("label") == "primer":
            continue
        pid = r["pid"]
        if r["type"] in ("down", "rdown", "mdown"):
            held[pid] = r["t"]
            dragged.discard(pid)
        elif pid in held and r["type"] in ("drag", "rdrag", "mdrag", "up", "rup", "mup"):
            gaps.append((r["t"] - held[pid], pid in dragged or r["type"].endswith("drag")))
            held[pid] = r["t"]
            if r["type"].endswith("drag"):
                dragged.add(pid)
            else:
                n += pid in dragged
                del held[pid]
    worst = max((g for g, in_drag in gaps if in_drag), default=None)
    if worst is None:
        return
    rep.check("drag flow", worst <= 0.04, f"{n} drags; longest pause between events with the button down "
              f"{worst * 1000:.0f} ms (want <= 40)")


def typing(trace: list[dict], rep: Report, wpm: float) -> None:
    keys = [r for r in trace if r["k"] == "event" and r["type"] in KEYS]
    shift_held = False
    caps = caps_ok = 0
    for r in keys:
        if r["type"] == "flags" and r.get("code") in (0x38, 0x3C):
            shift_held = bool(r["flags"] & SHIFT_MASK)
        elif r["type"] == "keydown" and "A" <= r.get("chars", "") <= "Z" and len(r["chars"]) == 1:
            caps += 1
            caps_ok += shift_held and bool(r["flags"] & SHIFT_MASK)
    shift_problems = []
    if caps and caps_ok < caps:
        shift_problems.append(f"{caps - caps_ok}/{caps} capitals typed without Shift held")
    if shift_held:
        shift_problems.append("Shift left down at the end")
    # Typed keys, not shortcuts (cmd/ctrl/option held): a shortcut ends a run of typing.
    shortcut_mask = 0x100000 | 0x40000 | 0x80000
    downs = [r for r in keys if r["type"] == "keydown" and r.get("code") not in MODIFIER_CODES]
    if wpm <= 0:
        if caps or shift_problems:
            rep.check("typing", not shift_problems, f"instant typing (cadence not judged); {caps_ok}/{caps} capitals "
                      "with Shift" + ("; " + "; ".join(shift_problems) if shift_problems else ""))
        return
    if len(downs) < 20:
        return
    # A run of typing ends at a shortcut, a navigation key (arrows, BackSpace, Tab, Escape: pressed, not
    # typed), a click, or a long pause.
    nav = {0x33, 0x75, 0x7B, 0x7C, 0x7D, 0x7E, 0x30, 0x35, 0x73, 0x77, 0x74, 0x79}
    clicks = sorted(r["t"] for r in trace if r["k"] == "event" and r["type"] in BUTTONS and r.get("label") != "primer")
    runs, cur = [], []
    for q in downs:
        clicked = cur and any(cur[-1]["t"] < c < q["t"] for c in clicks)
        if q["flags"] & shortcut_mask or q.get("code") in nav or clicked or (cur and q["t"] - cur[-1]["t"] > 1.5):
            runs.append(cur)
            cur = []
        if not q["flags"] & shortcut_mask and q.get("code") not in nav:
            cur.append(q)
    runs.append(cur)
    runs = [r for r in runs if len(r) >= 20]
    if not runs:
        return
    ikis = [q["t"] - p["t"] for r in runs for p, q in zip(r, r[1:])]
    mean = statistics.mean(ikis)
    cv = statistics.pstdev(ikis) / mean
    eff = 60 / (mean * 5)
    open_down: dict[int, dict] = {}
    dwells, rollovers = [], 0
    down_keys = 0
    for r in keys:
        if r["type"] == "keydown" and r.get("code") not in MODIFIER_CODES:
            if open_down:
                rollovers += 1
            open_down[r["code"]] = r
            down_keys += 1
        elif r["type"] == "keyup" and r.get("code") in open_down:
            dwells.append(r["t"] - open_down.pop(r["code"])["t"])
    problems = list(shift_problems)
    if not 0.7 * wpm <= eff <= 1.25 * wpm:
        problems.append(f"{eff:.0f} WPM, configured {wpm:.0f}")
    if cv < 0.2:
        problems.append(f"interval spread {cv:.2f} looks mechanical (want > 0.2)")
    dm = statistics.median(dwells) if dwells else 0
    dcv = statistics.pstdev(dwells) / statistics.mean(dwells) if len(dwells) > 1 else 0
    if not 0.035 <= dm <= 0.18 or dcv < 0.1:
        problems.append(f"key holds median {dm * 1000:.0f} ms, spread {dcv:.2f} (want 35-180 ms, > 0.1)")
    if wpm >= 100 and down_keys >= 30 and rollovers == 0:
        problems.append("no rollover at speed")
    rep.check("typing", not problems,
              f"{sum(len(r) for r in runs)} keys: {eff:.0f} WPM (configured {wpm:.0f}), interval spread {cv:.2f}, "
              f"holds median {dm * 1000:.0f} ms, {rollovers} rollovers, {caps_ok}/{caps} capitals with Shift"
              + ("; " + "; ".join(problems) if problems else ""))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trace", required=True, help="the helper's PUTER_USE_TRACE file")
    ap.add_argument("--probe", help="PuterUseProbe's log, to check what was received")
    ap.add_argument("--wpm", type=float, default=140, help="PUTER_USE_TYPING_WPM used (default 140)")
    ap.add_argument("--speed", type=float, default=1, help="PUTER_USE_CURSOR_SPEED used (default 1)")
    args = ap.parse_args()
    trace, probe = load(args.trace), load(args.probe)
    rep = Report()
    drawn_vs_sent(trace, rep)
    if probe:
        received_vs_sent(trace, probe, rep)
    paths(trace, rep, args.speed)
    clicks(trace, rep, instant=args.speed <= 0)
    drag_flow(trace, rep)
    typing(trace, rep, args.wpm)
    return 0 if rep.print() else 1


if __name__ == "__main__":
    sys.exit(main())
