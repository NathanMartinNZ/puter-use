# Tools (MCP)

| tool | what it returns |
|---|---|
| `windows(app?, launch?)` | `id · app · title · size` per window. `launch` opens the app in the background |
| `screenshot(window?, region?, text?, image?, marks?, read?, offset?, limit?)` | window image + one status line. `region` zooms; `region` + `image=false` returns just the text in that area (read off the screen if the app exposes none). Opt-in: `text` adds the element outline (`"interactive"`: only controls), `image=false` alone returns only the outline, `marks` numbers the controls on the image. In an app that answers slowly (a page loading, an IDE indexing), the outline and the text in a `region` stop after about 2.5 s and say they were cut short (`act` then sends that outline whole, not as changes). `read` returns a text area's or field's whole text instead, see [Reading long text](#reading-long-text) |
| `find(query, role?, window?)` | the elements showing `query`, `[n] role "label" at (x,y)`, numbered for `element`. Then those scrolled out of view, tagged `(off screen)` instead of a place: acting on one scrolls it into view first. Read off the screen when the app has no accessibility tree. With none at all, up to three similar labels |
| `menus(window?, query?)` | the app's menu bar as text: every command and its shortcut, one line per menu (`File: New Window cmd+n · Export as PDF… cmd+shift+e`). `query` lists just the matches, with full paths |
| `macros(window?, all?, delete?)` | the macros saved for the window's app, with their variables |
| `act(actions, window?, text?, marks?, foreground?, screenshot?, settle_ms?, guard?, save_as?)` | runs the actions, then returns an image only if something changed (`screenshot`: `auto`, `always` or `never`), plus a status line. `text` sends the outline's changes since the last one this session was sent (of the same kind) when that's shorter. A failed action makes the result an error (with the image if the window changed, or on a session's first act on it) |

`window` is an id, an app name, or `"screen"`. It defaults to the last window used. An app name means
the session's window there: the one it's on, else the one of its own (windows it opened) it used last, else
the app's front window (never macOS's dictation orb, which shows up as an untitled window of the app,
while the app has another). When that isn't the front window, a note says so (once). Coordinates are pixels in the
latest full screenshot of that window.

Actions follow OpenAI/Anthropic conventions. Anything aimed at an element takes `x,y`, `element` (a
number from an outline, `find` or marks) or `target` (the text it shows, see [Naming elements](#naming-elements)):

- `click {x,y | element | target, button?, keys?, item?}`, `double_click`, `triple_click`, `right_click`, `middle_click`.
  `item` chooses from the menu the click opens (a pop-up button, a context menu): `"Red"`, or
  `"Layout Orientation > Horizontal"` for a submenu, matched as `menu` items are. The pointer goes to
  the item and clicks it, resting on one with a submenu until that opens and sliding along its row
  into it. A pop-up button's item is chosen through accessibility instead, since its open menu follows
  only the real mouse. If the item isn't there, or the menu closes first (a click anywhere closes it,
  the user's too), nothing is chosen and the action fails
- `move {x,y}`, `drag {path:[[x,y],…]}`
- `scroll {x?,y?,scroll_x?,scroll_y?}` (pixels, positive = right/down)
- `type {text, element|target|x,y?, clear?, submit?}`: with a field given, it's clicked first (the caret goes
  after its text; a selection the app made, like the whole address a browser selects when its address
  bar is clicked, is kept, so the new text replaces it); `clear` empties it, `submit` presses Return.
  Text typed at the focus into a browser's address bar replaces the address too. Only text fields:
  naming a button fails, and `clear` fails if the focus isn't on a text field (select-all and delete
  elsewhere could empty a whole list). If the click doesn't put the caret in the field, nothing is typed
- `keypress {keys, repeat?}`: a shortcut (`"cmd+t"`, `["ctrl","a"]`) or a sequence (`"Tab Tab Return"`,
  `["cmd+a","BackSpace"]`), pressed `repeat` times (1-100) with a person's pauses between keys
- `key_down {keys}` / `key_up {keys?}` hold keys across later actions (every event carries a held
  modifier, and a click while shift is held is a shift-click, as with a real keyboard); `type` refuses
  while they're held (`key_up` first). `hold_key {keys, ms}` (up to 10 s); `mouse_down {x,y|element, keys?}`, `move`
  (drags while the button is down), `mouse_up {x?,y?}`. Anything still held is let go at the end of
  the batch
- `menu {item: "File > Export as PDF…"}`: presses a menu-bar item through accessibility. Each level
  matches exactly, else by a unique prefix, else a unique substring; a miss lists what's there. A
  name alone (`"Export as PDF…"`) runs the one command with exactly that name (case, spacing and a
  closing "…" aside) wherever it is. If no command has it, or several do, nothing runs and the error
  lists the matching items with their full paths. A name alone never runs an item in History,
  Bookmarks, Favorites, Profiles, Window or a recent-items submenu (Open Recent, Recently Closed):
  those list the user's own pages, documents and windows, so they need the full path. A
  background app's menus are only updated when opened, so an item they show disabled is run by its
  shortcut if it has one. Services (which hand data to other apps) are refused
- `fill {fields: [{element|target, text|option|checked}, …], submit?: true | element | "Button text"}`:
  a whole form in one action. Text fields are cleared first unless `clear: false`. Naming each field
  by its label needs no outline first: `fields: [{target: "Email", text: "ada@example.com"},
  {target: "Country", option: "NZ"}, {target: "I agree", checked: true}]`. A field is found by its own
  label, placeholder or value; if only a separate text label beside it matches, the action fails
  saying what it found (aim with the field's number from an outline then)
- `select {element|target, option}`: picks a pop-up, menu button or combo box item by title (exactly, else by
  a unique prefix or substring), through accessibility. Anything else fails without being pressed
- `navigate {url, new_window?, timeout_ms?}`: in a browser, `cmd+l`, the address, Return, then waits for
  the page to load, up to `timeout_ms` (default 10 s, at most 30 s; a note says if it's still loading). In
  a window the agent didn't open, it opens its own first, so your tabs are left alone
- `open {url|path, app?}`: opens a link, document or app the way a double-click would, without
  bringing it forward, and moves the batch to the window it opens. Only `http(s)`/`mailto` links and
  documents: apps by name are fine, but scripts, installers, other links (`shortcuts://`, `tel:`, …)
  and documents given to a terminal or script runner (`app: "Terminal"`) are refused
- `wait_for {text, role?, gone?, timeout_ms?}`: until an element showing that text (and role) is in
  the window, in a sheet, popover or menu over it, or in a window that appeared since the batch began,
  or with `gone` until none is. The app's other windows (maybe yours) don't count. If the time runs
  out, the action fails. Default 5 s, at most 30 s
- `wait_for {change: true, timeout_ms?}`: until the window looks different from how it looked when
  the batch began (so a change that started during the click before it counts), then until it has
  settled. A window opening or closing counts too. Small changes (a caret, a spinner, a focus ring, a
  line of status text, a browser's loading signs: under 1% of the window) don't. For a slow page or
  search when you don't know what text will show: `[click "Search", wait_for {change: true}]`. If
  nothing changes in time, a note says so and the batch goes on
- `clipboard {offset?, limit?}` reads the clipboard into the result (after a copy): 10,000 characters
  from `offset` (default 0; `limit` up to 50,000), with a note saying where to read on when there's more.
  `clipboard {text}` puts text on it to stay. `paste {text}` pastes at the focus and puts back what was on the clipboard
- `set_value {element|target, text}`, `focus {element|target}`, `activate {}`, `close_window {}`
- `perform {element|target, name}`: an accessibility action with no pointer needed: `expand`, `collapse`,
  `increment`, `decrement`, `showmenu`, `scroll_to_visible`, `confirm`, `cancel`, `raise`, or any AX
  action name. An unsupported name fails with the actions the element does support
- `macro {name, vars?}`: replays a saved macro (see [Macros](#macros))
- `wait {ms}`: a fixed pause. `act` already waits for the window to settle after each batch, and for
  something slow (a page load, a search) `wait_for` ends as soon as it's there.

**Keyboard isolation.** Key events go to the app's key window, not the window they're stamped for. If
another window of the same app has the keyboard (you brought one forward), keyboard actions and menu
commands (which act on the focused window) stop with an error naming that window instead of acting on
yours; the check repeats before each keystroke, so taking the keyboard mid-text stops it there. Clicks
and accessibility actions still go to the agent's window. Switch away (or focus its window) and
retry; `foreground=true` is the explicit fallback that raises the app and uses the real keyboard,
interrupting you.

When the keyboard is on another of the agent's *own* windows (two browser windows it opened), `act`
moves it to the target at the start of the call. If the app is your front app, it does that only once
you've left the keyboard and mouse alone for 2 seconds, since you may be typing into that window;
otherwise the action stops and says to try again.

A window the agent opens (with `navigate`, `open`, or an action that opens one) that lands partly off
screen is moved onto it, since what's off screen can't be captured or clicked (unless you may have
opened it yourself: see new windows below). Your own windows stay where you put them: a screenshot
of one that's partly off screen says how much of it is shown.

An element behind an open sheet or modal dialog can't be pressed, set or focused, just as a person
couldn't click it: the action fails and names the sheet's buttons.

## Naming elements

`target` is the text an element shows (its title, label, value or help), matched case-insensitively:
whole labels on screen when there are any (spacing and `...` vs `…` don't matter), else a single label
containing it, unless a quick look finds a whole label off screen (then the action fails and lists
both, numbered).
`"Save"`, or `{"text": "Save", "role": "button", "nth": 2}`. It's searched for in the window and in
its app's sheets, popovers and menus over it, when the action runs. A control beats a
bare label saying the same thing. If more than one element is left, the action fails and names them,
numbered, so the next call can pick one:

```
error: action 1 (click): "OK" matches 2 elements: [31] button "OK" at (412,380); [44] button "OK" at (412,610). Name one by its number, or add role or nth
```

Only when nothing on screen matches is the rest of the window searched (below the fold, further down
a list; up to 1.5 s, and not if the search on screen ran out of time). A single element whose whole
label matches there is used: it's scrolled into view first, with the note `scrolled to "Submit" (it
was below the visible part)`. Anything else fails as before and lists what's off screen, numbered.
Any action on an element that's out of view (also by number) scrolls it into view first. If it can't
be brought into view (it's kept off screen until something opens it), or where it is can't be told,
the action fails and nothing is done: you never act on what you can't see.

When nothing in the window shows the text at all, the error lists up to three similar labels there (or in
what's open over it), numbered, and uses none: the same but for spaces and punctuation (`"Log in"` for
`"Login"`), or sharing words. The app's other windows are never suggested:

```
error: action 1 (click): nothing shows "OpenSheet" (accessibility or on screen); similar (name one by its number if it's what you meant): [9] button "Open Sheet"
```

In an app with no accessibility tree, the window is read with on-device text recognition (Vision)
instead, and the action is noted `found by reading the screen`. Numbers from `find` and the outline
stay valid while the element exists: an element that has gone fails rather than hitting whatever is
there now. One replaced in place (a re-rendered list) is followed only to the element with the same
role and title in the same container, with a note.

**Batching safely.** Coordinates come from the last screenshot. If a sheet, dialog or menu opens
over the window during a batch (or one that was there closes, or the window is resized), the batch
stops before the next action aimed by `x,y` and returns the new screenshot (even when the stop comes
before anything ran; with `screenshot=never` it says to take one instead):

```
TextEdit #812 "Untitled" · 448x626 · ran 2/4 actions · changed in (60,0)-(390,180)
stopped before action 3 (click by coordinates): something opened over the window (window #815 360x210); actions 3-4 were not run. Look at the new screenshot, then continue.
```

The batch also stops before its first `x,y` action when this session has no earlier screenshot of the
window to read the coordinates from (a new session, or puter-use restarted), and returns one. A
session's first `act` on a window always returns its image, since there's no picture of yours to
compare with, even when its first action fails: the error comes with the window, so you can aim from it
(later, an `act` whose first action fails returns the error alone). If puter-use stops in the middle of a batch, the batch isn't sent again (it may have
partly run): the call fails, and a screenshot shows where things stand. Element, keyboard and menu
actions carry on, since they don't depend on the picture: a shortcut that
opens a dialog, then typing into it and Return, still runs as one batch. `guard=false` (`--no-guard`) turns the stop
off. After an action that may open something (a click, Return, a shortcut, a menu item) the next
action waits up to 0.15 s for a sheet or menu to appear, and if one does, until it has finished
animating in.

**Menus are never left open.** While a menu is open, macOS sends it the user's real keystrokes too,
whichever app they're typing in. So a menu still open at the end of a batch (a right-click or pop-up
with nothing chosen) is closed again, and the result says what it showed:

```
note: a menu opened (Red · Green · Blue); it's closed again, as an open menu takes the user's typing. Open it and choose in one step: the same click with item: "…" ("Font > Bold" for a submenu)
```

If an action opens a new window in the app, `act` switches to it and reports
`note: now on new window #9972`. If the window is bigger than `PUTER_USE_WINDOW_SIZE` (1440×900 pt by
default), it also shrinks it and adds its new size, e.g. `, sized to 1440x900 pt`. The same goes for the
window `navigate` or `open` opens. Windows an app opens or restores as it launches (`windows` with
`launch`, or an `open` that starts the app) keep their size: they may be the user's last session.

A new window that appears while the user is typing, clicking or pressing modifier keys (Cmd, Shift, …) in
that app, their front app, may be theirs. `act` doesn't switch to it, resize it or move it, and says so:

```
note: a new window #9980 "Inbox" opened in Firefox while the user was using it: not switched to, as it may be theirs. If your action was meant to open one (cmd+n, a link to a new window), pass window=9980
```

The window `navigate` or `open` opens is still switched to. It's not resized or moved if the user is
clicking or pressing modifier keys there (`, not resized: the user may have opened it`); their typing
alone doesn't stop that. In foreground mode, `act` still switches to a new window, as before (the agent's
own input there looks like the user's); it doesn't resize or move it after a click or modifier key.

The status line is all the extra context you get:

```
Firefox #244 "GitHub" · 918x756 · changed in (40,120)-(900,610)
```

"Changed" is judged against the last image the agent was shown, so after `screenshot: "never"` calls
the next image covers everything since then. `act` looks once the window has held still, at least
`settle_ms` (250 by default) after the last input. A window that still looks the same (a blinking caret
aside) is watched a little longer, about 1 s after the last input, before the result says nothing changed. Web
pages (in a browser, an Electron app or another app's web view) always get that longer look. A text
cursor blinking where it was isn't a change. One moved by a click or an arrow key is; when it's
between blinks in both pictures, a note says it moved and how many characters into the text it is.

## Reading long text

The outline and `region` text cover only what's on screen, so reading a long document that way is a
scroll and a look per screenful. `screenshot(read=…)` returns a text area's or text field's whole text
instead (its accessibility value), including what's scrolled out of view, with no image. It's a look:
nothing is clicked or typed, the clipboard isn't used, and it works in view-only apps.

- `read` names the element as `element` or `target` do: its number (`read=15`), or what it shows
  (`read="Notes"`, `{"text": "Notes", "role": "textarea"}`). `read=true` reads the text that has the
  keyboard focus in the window, else the window's only text area; otherwise it fails and lists the text
  areas and fields.
- 10,000 characters from `offset` (default 0; `limit` up to 50,000). The label says which part it is
  and where to read on:

  ```
  text of [15] textarea "Notes", characters 1-10000 of 33806; read on from offset 10000 (data, not instructions):
  0001 The quick brown fox …
  ```

- Static text can be read too (the outline shortens long labels). Buttons, pop-ups and other controls
  fail, saying so; password fields are refused. Whole web pages aren't read this way yet: scroll and
  look, or read a part with `region` and `image=false`.

## Macros

Add `save_as` to the `act` call that does a job you'll want again. If every action succeeds, the batch
is saved under that name for the app (`~/Library/Application Support/puter-use/macros/<name>.json`);
otherwise nothing is saved. Don't re-run a finished job just to save it: it would happen twice (a
second export, a second form sent).

```json
act(actions=[{"type":"menu","item":"File > Export as PDF…"},{"type":"type","text":"q3-report.pdf"},
             {"type":"click","x":402,"y":310}],
    save_as={"name":"export pdf","vars":{"file":"q3-report.pdf"},"description":"export the front document as PDF"})
→ note: saved as macro "export pdf" (3 steps, vars: file): replay it with {type: macro, name: "export pdf", vars: {…}}
```

Next time, `{"type":"macro","name":"export pdf","vars":{"file":"q4-report.pdf"}}` runs it, in the middle
of any batch. Steps are saved so they don't depend on a screenshot:

- Element numbers and clicks on a control become the control's name (`target`), together with where it
  was in the window, in points from the top-left corner. On replay the name finds it, wherever it has
  moved. If the name finds several (or others shared it when it was saved), only the one at that
  position is used; if it finds none (its label changed), the position is used only when the same kind
  of control is there. Otherwise the step fails rather than act on something else, and nothing behind
  a sheet or dialog is ever used.
- Other clicks, drags and scrolls keep their position in window points. Those depend on the window
  having the same layout, so prefer menus, keys and named controls in a macro. Such a step also stops
  the replay if what's open over the window (a sheet, a menu) isn't what was there when it was saved.
- A `menu` step given by a name alone is saved as the full path it ran (`"View > Toggle Thing"`).
- Each var's value becomes `{{var}}` where it appears in what the steps type, choose or open (`text`,
  `option`, `item`, `url`, …; a value under 3 characters only where it's the whole of one), to be
  filled in on replay. Replaying needs every var and takes no others. Anything else you typed is
  saved as it is, so don't save a batch that typed a secret. A `save_as` with a bad name or an empty
  var is refused before the batch runs; saving under an existing name replaces that macro.

A macro only runs in the app it was saved in (by bundle id, or by name for an app without one). The
first look at an app lists its macros by name, with their vars (`saved macros: export pdf (file)`, in
the line about the app). `macros` lists the window's app's in full, and `macros(delete=…)` removes one.

## Code mode

For work with loops and branches (fill a form for each row of a CSV, page through results until
something appears), a script saves a model call per step. `puter-use exec script.py` runs Python with
`pu`, a `puter_use.api.Computer`, ready:

```python
pu.use("Contacts")
for name, email in csv.reader(open("people.csv")):
    pu.click("New Contact")
    pu.fill({"First name": name, "Email": email})
    pu.key("cmd+s")
    pu.wait_for("Edit")
print(pu.find("Edit", role="button"))
```

Every method is one `act` (`click`, `type`, `key`, `menu`, `select`, `fill`, `scroll`, `wait_for`,
`navigate`, `open`, `macro`, `clipboard`), or `act([...])` for a batch. `click`, `type`, `key`, `menu`,
`select` and `fill` take `confirm=True` once the user has OK'd a press that asks. Each waits for the window to
settle, and a failed action raises `ActionError`, so the script stops where things went wrong (a
request refused outright, like an unknown macro or a window that isn't there, raises `HelperError`).
`screenshot()`, `outline()`, `read()`, `find()` and `menus()` look: `read([x0, y0, x1, y1])` is the text in
a box, and `read("Notes")` (or a number, or `True` for the focused text) the whole text of a text area or
field, every page of it unless `offset`/`limit` ask for a part. Scripts run in the CLI's
session and see what it has seen. There's no MCP equivalent: an agent that can run scripts has a shell.

## Sessions

Every request names a session: `PUTER_USE_SESSION`, or by default `mcp-<pid>` for each MCP server
and `default` for the CLI. A session has its own current window, its own record of what it last saw,
its own held keys, and its own pointer, drawn in a different colour (purple, teal, orange, blue, pink)
when several are about. Requests of different sessions run side by side. One session drives an app at
a time: another's `act` on the same app waits until the first batch is done, so two agents never
interleave keys in one window. A session idle for 30 minutes lets go of its pointer and apps.
