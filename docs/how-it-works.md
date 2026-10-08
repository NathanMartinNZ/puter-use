# How it works

```
agent ──MCP (stdio)──▶ puter-use (Python) ──JSON over Unix socket──▶ PuterUse.app (Swift, menu-bar-less)
         or CLI                                                        ├─ ScreenCaptureKit per-window capture
                                                                       ├─ Accessibility tree + AX actions
                                                                       ├─ CGEvent.postToPid + window stamping
                                                                       └─ agent pointer: human-like path, drawn + sent
```

`PuterUse.app` owns the macOS permissions, so they work the same whichever harness launches the
MCP server or CLI. It starts on demand.

Background input uses the same techniques as OpenAI's helper. They were reverse-engineered by
open-codex-computer-use and cua-driver, and verified here on macOS 27:

| problem | fix |
|---|---|
| events must reach one app, not the cursor | `SLEventPostToPid`. Mouse events are stamped with the window: fields 51/91/92, pid field 40, and the private `CGEventSetWindowLocation` |
| a background window swallows the first click to activate itself | a primer click at window-local (-1,-1), then the real click; skipped once the window is the key window of an app held active, where clicks count as they come |
| background apps ignore key equivalents and route keys to no window | an AppKit-only activation record, plus "make key window" records (`SLPSPostEventRecordTo`). Your frontmost app and keyboard focus don't change |
| Chromium ignores background key equivalents | `cmd+…` is pressed as the matching menu item through accessibility |
| WindowServer accelerates synthetic scrolls | scroll is sent as a paced trackpad gesture (began/changed/ended) |
| Firefox has no accessibility tree until asked | `AXEnhancedUserInterface` is set the first time an outline comes back empty |
| menus and popovers close when the app deactivates | the target stays AppKit-active between calls. It's released on `release`, on switching apps, or after 2 idle minutes. If you bring the app forward yourself, the hold is simply dropped: an app that's really in front is never told it's inactive (Firefox would ignore your clicks until you switched apps) |
| a primer click outside a menu dismisses it | clicks that land on the app's own menu, popover or sheet go to that window, without a primer |

A click on a button, checkbox, pop-up, link or other control named by element uses `AXPress` and
skips event routing altogether (the pointer still travels there, so the app sees it hover). Anything
else named by element, such as a text field or a list row, gets a real click at its centre, since
where a click lands matters there.

Verified with Claude/VS Code in front and the real cursor never moving:

- **TextEdit:** click-to-place, typing including Unicode, `cmd+a`/`cmd+z`, double-click a word, drag-select, scroll
- **Calculator:** exactly-once button clicks
- **Firefox:** `cmd+n`, `cmd+l` + typing a URL, pixel and element clicks on links, page scroll, the web accessibility outline, `close_window`
- **Context menus (TextEdit):** right-click opens one, clicking an item opens its submenu, Escape closes it
- **Menus opened by a click (the probe):** `right_click … item: "Layout Orientation > Horizontal"` and a
  pop-up's `click … item: "Green"` choose in one step; a menu left open is closed with a note
- **New windows (Firefox):** `cmd+n` makes the new window the target (with `PUTER_USE_WINDOW_SIZE=1280x860`
  it is also sized to 1280×860 pt). Text in a region (a Hacker News row) reads back exactly

## Human input

The agent's input is modelled on a person's, and what you see is exactly what the app gets.

**Pointer.** One motion drives both the purple cursor and the mouse events the app receives. Every
frame (120 Hz) the next point of the path is drawn *and* sent to the app as a mouse-moved event (a
dragged event while a button is held). A click goes down only when the pointer arrives. The path is
modelled on human reaching, which is also what OpenAI's helper approximates:

- **Curved path.** A cubic Bézier that bulges 4–10% to one side early and straightens on approach.
  Several candidate arcs are scored and the one that stays over the target window wins, since the
  cursor is drawn just above that window.
- **Duration from Fitts's law.** 0.11 s + 0.09 s · log₂(1 + distance/14 pt), clamped to 0.14–0.85 s.
- **Bell-shaped speed.** A minimum-jerk profile, `10t³ − 15t⁴ + 6t⁵`.
- **Overshoot and correction.** On moves over 160 pt, the pointer goes 1.5–3.5% (at most 12 pt) past the
  target, then makes a short corrective move back.
- **Drags** follow the agent's points exactly (they matter when drawing or selecting). Gentle bends
  are taken in one bell-shaped sweep; at a sharp corner (over 55°) the hand slows to a stop, pauses a
  beat and sets off again.
- **Holding still** with a button down isn't perfectly still: the pointer makes a faint tremor (a
  fraction of a point, ~10 Hz), sent as dragged events, as a hand on a mouse does.
- **Clicks** go down a beat (40–220 ms) after the pointer arrives and hold the button for 45–140 ms,
  like a finger; a double-click's clicks are 70–200 ms apart. A click with modifiers (`keys: "shift"`)
  presses the modifier keys before setting off and releases them after.
- **Back on a window** after the pointer was hidden (20 s idle), it starts where it was left, so the
  app never sees it jump.
- **Life.** The pointer leans with its horizontal speed, sways slowly when idle, and dips and ripples
  when it clicks. With `PUTER_USE_CURSOR=0` the path is still followed, just not drawn.

**Typing.** Text is typed like a fast, practised typist, at `PUTER_USE_TYPING_WPM` (default 140):

- **Rhythm.** Intervals between keys are skewed and vary with the pair of keys: hands alternating is
  quick, the same finger twice is slow, common pairs like "th" are quick, and digits, symbols and
  Shift take a longer reach. People pause after punctuation, at line ends, and now and then before a
  word.
- **Keys** are held for a varying time (about 80 ms at 140 WPM), and at speed the next key often goes
  down before the last comes up (rollover).
- **Modifiers are real key presses.** Shift goes down before a capital and comes up after it.
  Shortcuts press their modifiers one after another, then the key.

**Long text is pasted**, as people do: a stretch longer than `PUTER_USE_PASTE_OVER` characters (default
100, about a sentence; `0` = always type) goes in with Cmd+V after a short pause. Newlines are still
Return key presses, so a multi-paragraph text pastes each long paragraph and presses Return between
them. The clipboard is borrowed: the text is marked transient (clipboard managers skip it) and your
own contents are put back 0.6 s later, unless you copied something in between.

**Selecting text in the background.** AppKit text views (TextEdit, Notes, Mail's editor, …) judge a
drag and a shift-click by the *hardware* mouse button and Shift key rather than by the events they
receive, and in the background those are up. A hand-paced drag would select a character or two, a
shift-click would only move the caret, and a click inside a selection would leave the caret at its
start. The gestures still go out as a hand makes them; afterwards puter-use reads the text under the
start and end points through accessibility and, if the app didn't select what the gesture covered,
sets that selection itself. A click inside a selection would leave those views waiting to learn
whether the selection is being dragged away, so the caret is put at the click point first and the
click lands on plain text. Double- and triple-click (word, line) and Shift+arrow keys work as they
are. Apps that handle the events themselves (browsers, Electron, custom views) need none of this.

The cost is time: a click or move takes 0.14–0.85 s, and a 100-character sentence takes about 9 s to
type. That's still small next to a model call, so batching actions remains the big win.
`PUTER_USE_CURSOR_SPEED` and `PUTER_USE_TYPING_WPM` change the pace; `0` makes either instant.

**Checking it.** `scripts/probe.sh` starts PuterUseProbe, a test window that logs every event it
receives. Run actions against it with `PUTER_USE_TRACE=<file>` (the helper logs every event it sends
and every cursor frame it draws), then `scripts/check_motion.py --trace <file> --probe <probe log>`
checks that every drawn frame was sent, every sent event arrived, the paths are curved, timed by
Fitts's law, bell-shaped and overshoot on long moves, clicks land on arrival, and typing has a human
rhythm at the configured speed.

**Why not Screen Sharing?** A macOS login session has exactly one cursor. Screen Sharing into your
own session moves your real pointer. A separate virtual session (a second user account) gets its own
cursor, but it can't see your apps, windows or logins. OpenAI's implementation (shipped inside
ChatGPT.app as "Codex Computer Use.app") uses the per-window approach above, and so does this.
