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
| background apps ignore key equivalents and route keys to no window | an AppKit-only activation record, plus "make key window" records (`SLPSPostEventRecordTo`). On a new hold the app has no key window, so shortcuts like cmd+a would find nothing to act on: the primer click is spent on the window just before the first key or menu command goes out, after that action's checks. Your frontmost app and keyboard focus don't change |
| Chromium ignores background key equivalents | `cmd+…` is pressed as the matching menu item through accessibility |
| WindowServer accelerates synthetic scrolls | scroll is sent as a paced trackpad gesture (began/changed/ended) |
| a long scroll at the end would go on for seconds past it | every few steps it looks under the pointer: the scroll bar at the end, or the content no longer moving (after moving, or with its end in view), stops it with a note |
| Firefox has no accessibility tree until asked | `AXEnhancedUserInterface` is set the first time an outline comes back empty |
| menus and popovers close when the app deactivates | the target stays AppKit-active between calls. It's released on `release`, on switching apps, or after 2 idle minutes. If you bring the app forward yourself, the hold is simply dropped: an app that's really in front is never told it's inactive (Firefox would ignore your clicks until you switched apps) |
| a primer click outside a menu dismisses it | clicks that land on the app's own menu, popover or sheet go to that window, without a primer |

**Keyboard isolation.** Key events follow the app's key window, whatever window they're stamped with.
So before every key, puter-use checks that the target window is still the app's key window. If another
window of the same app has it (the user brought one forward), typing, shortcuts, modifier-clicks and
menu commands (which act on the focused window) stop and say which window has the keyboard, rather
than acting on the user's. Clicks are stamped with their window and still go to the agent's. The check
happens again before each keystroke while typing, so taking the keyboard mid-text stops it there.
While the app is in the background, its key window never changes by itself, so keys for one of the
agent's own windows first move the keyboard there with a primer click, as a click on it would; never
while the user is in the app, and never onto a window of the agent's the user has used since. When
keys, shortcuts, modifier-clicks or menu commands are still blocked because the user is in another
window of that app (or switched in after a background move, or focus sits on a non-agent window),
`PuterUse.app` by default shows a non-activating floating HUD (`NSPanel` with `.nonactivatingPanel`,
never stealing keyboard focus while displayed) asking the user to **Switch Window** / **Allow** or
**Decline**. Approving raises and focuses the target window (or flashes it if the user is in another
app) and grants a temporary focus lease (immediately revoked on any user key press, click, scroll or
app switch) so the blocked action completes cleanly; declining or timing out after 30 s stops the
action with a per-app cooldown (`PUTER_USE_FOCUS_PROMPT=never` disables the popup). When the
agent's window already has the keyboard of the user's front app, it's the window they're in: keys
there go only once they've left the keyboard and mouse alone for 2 seconds (checked before each key),
else they stop and say to try again.
`foreground=true` is the explicit fallback: it raises the app and uses the real keyboard, interrupting
the user.

**Windows that stop drawing.** Firefox stops drawing a window that gets fully covered while it isn't
its key window, and drops its page's accessibility tree, until part of it shows again; one that was its
key window as it got covered draws on. So when one of the agent's own windows is found not drawn (on
evidence: see [Tools](tools.md)), puter-use by default brings its app forward for a moment: the window
is made key and raised (as `activate` does), the app is brought to the front, and once the window draws
again (its page has a tree again, or a capture differs from the stale one; looked at every 50 ms, for
1.2 s at most) the app the user was in is brought back. Usually that's well under a second. Only while
the user has left the keyboard and mouse alone for 3 seconds (the HID system's own times, which
puter-use's input doesn't touch), never while they're in that app or a full-screen one, never for a
window on another Space or one the user has used, and once a window in 30 seconds at most. A key press,
click or move of theirs during it brings their app back at once. The app's hold (above) is sent again
afterwards, as a new one. A note tells the agent each time. `PUTER_USE_BRING_FORWARD=never` turns it
off, and a Firefox started with `MOZ_WINDOW_OCCLUSION=0` never needs it (see
[Configuration](configuration.md#keeping-your-firefoxs-covered-windows-drawn)).

A click on a button, checkbox, pop-up, link or other control named by element uses `AXPress` and
skips event routing altogether (the pointer still travels there, so the app sees it hover). Anything
else named by element, such as a text field or a list row, gets a real click at its centre, since
where a click lands matters there.

Web pages in Firefox (and other Gecko browsers) are the exception: Gecko's `AXPress` fires no pointer
events, so controls that listen for `pointerdown` ignore it. There a control gets a real click, at a
point the app's hit test says is on it: its text, its centre or a quarter point. If something else is
over every point (a banner, an overlay), or another window of the app would take the click, it's
pressed through accessibility instead, with a note. Gecko's hit test doesn't see elements with no
accessible, such as an `aria-hidden` backdrop, so a click there lands on the backdrop, as a person's
would.

Verified with Claude/VS Code in front and the real cursor never moving:

- **TextEdit:** click-to-place, typing including Unicode, `cmd+a`/`cmd+z`, double-click a word, drag-select, scroll
- **Calculator:** exactly-once button clicks
- **Firefox:** `cmd+n`, `cmd+l` + typing a URL, pixel and element clicks on links, page scroll, the web accessibility outline, `close_window`
- **Context menus (TextEdit):** right-click opens one, clicking an item opens its submenu, Escape closes it
- **Menus opened by a click (the probe):** `right_click … item: "Layout Orientation > Horizontal"` and a
  pop-up's `click … item: "Green"` choose in one step; a menu left open is closed with a note
- **New windows (Firefox):** `cmd+n` makes the new window the target (with `PUTER_USE_WINDOW_SIZE=1280x860`
  it is also sized to 1280×860 pt; the default box is 1440×900). Text in a region (a Hacker News row) reads
  back exactly

## Human input

The agent's input is modelled on a person's, and what you see is exactly what the app gets.

**Pointer.** One motion drives both the purple cursor and the mouse events the app receives. Every
frame (120 Hz) the next point of the path is drawn *and* sent to the app as a mouse-moved event (a
dragged event while a button is held). A click goes down only when the pointer arrives. The path is
modelled on human reaching, which is also what OpenAI's helper approximates:

- **Curved path.** A cubic Bézier that bulges 4-10% to one side early and straightens on approach.
  Several candidate arcs are scored and the one that stays over the target window wins, since the
  cursor is drawn just above that window.
- **Duration from Fitts's law.** 0.11 s + 0.09 s · log₂(1 + distance/14 pt), clamped to 0.14-0.85 s.
- **Bell-shaped speed.** A minimum-jerk profile, `10t³ - 15t⁴ + 6t⁵`.
- **Overshoot and correction.** On moves over 160 pt, the pointer goes 1.5-3.5% (at most 12 pt) past the
  target, then makes a short corrective move back.
- **Drags** follow the agent's points exactly (they matter when drawing or selecting). Gentle bends
  are taken in one bell-shaped sweep; at a sharp corner (over 55°) the hand slows to a stop, pauses a
  beat and sets off again.
- **Holding still** with a button down isn't perfectly still: the pointer makes a faint tremor (a
  fraction of a point, ~10 Hz), sent as dragged events, as a hand on a mouse does.
- **Clicks** go down a beat (40-220 ms) after the pointer arrives and hold the button for 45-140 ms,
  like a finger; a double-click's clicks are 70-200 ms apart. A click with modifiers (`keys: "shift"`)
  presses the modifier keys before setting off and releases them after.
- **Back on a window** after the pointer was hidden (20 s idle), it starts where it was left, so the
  app never sees it jump.
- **Life.** The pointer leans with its horizontal speed, sways slowly when idle, and dips and ripples
  when it clicks. With `PUTER_USE_CURSOR=0` the path is still followed, just not drawn.

**Typing.** Text is typed like a fast, practised typist, at `PUTER_USE_TYPING_WPM` (default 280):

- **Rhythm.** Intervals between keys are skewed and vary with the pair of keys: hands alternating is
  quick, the same finger twice is slow, common pairs like "th" are quick, and digits, symbols and
  Shift take a longer reach. People pause after punctuation, at line ends, and now and then before a
  word.
- **Keys** are held for a varying time (about 55 ms at 280 WPM), and at speed the next key often goes
  down before the last comes up (rollover).
- **Modifiers are real key presses.** Shift goes down before a capital and comes up after it.
  Shortcuts press their modifiers one after another, then the key.

**Long text is pasted**, as people do: a stretch longer than `PUTER_USE_PASTE_OVER` characters (default
80; `0` = always type) goes in with Cmd+V after a short pause. Newlines are still
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

The cost is time: a click or move takes 0.14-0.85 s, and an 80-character line takes about 4 s to
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
