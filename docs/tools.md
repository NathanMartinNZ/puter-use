# Tools (MCP)

| tool | what it returns |
|---|---|
| `windows(app?, launch?)` | `id · app · title · size` per window. `launch` opens the app in the background |
| `screenshot(window?, region?, text?, image?, marks?)` | window image + one status line. `region` zooms; `region` + `image=false` returns just the text in that area (read off the screen if the app exposes none). Opt-in: `text` adds the element outline (`"interactive"`: only controls), `image=false` alone returns only the outline, `marks` numbers the controls on the image |
| `find(query, role?, window?)` | the elements showing `query`, `[n] role "label" at (x,y)`, numbered for `element`. Read off the screen when the app has no accessibility tree |
| `menus(window?, query?)` | the app's menu bar as text: every command and its shortcut, one line per menu (`File: New Window cmd+n · Export as PDF… cmd+shift+e`). `query` lists just the matches, with full paths |
| `macros(window?, all?, delete?)` | the macros saved for the window's app, with their variables |
| `act(actions, window?, text?, marks?, foreground?, screenshot?, settle_ms?, guard?, save_as?)` | runs the actions, then returns an image only if something changed (`screenshot`: `auto`, `always` or `never`), plus a status line. `text` sends the outline's changes since the last one this session was sent (of the same kind) when that's shorter. A failed action makes the result an error (still with the image) |

`window` is an id, an app name, or `"screen"`. It defaults to the last window used. Coordinates are
pixels in the latest full screenshot of that window.

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
- `type {text, element|x,y?, clear?, submit?}`: with a field given, it's clicked first (the caret goes
  after its text); `clear` empties it, `submit` presses Return. Only text fields: naming a button
  fails, and `clear` fails if the focus isn't on a text field (select-all and delete elsewhere could
  empty a whole list). If the click doesn't put the caret in the field, nothing is typed
- `keypress {keys, repeat?}`: a shortcut (`"cmd+t"`, `["ctrl","a"]`) or a sequence (`"Tab Tab Return"`,
  `["cmd+a","BackSpace"]`), pressed `repeat` times (1–100) with a person's pauses between keys
- `key_down {keys}` / `key_up {keys?}` hold keys across later actions (every event carries a held
  modifier, and a click while shift is held is a shift-click, as with a real keyboard); `type` refuses
  while they're held (`key_up` first). `hold_key {keys, ms}` (up to 10 s); `mouse_down {x,y|element, keys?}`, `move`
  (drags while the button is down), `mouse_up {x?,y?}`. Anything still held is let go at the end of
  the batch
- `menu {item: "File > Export as PDF…"}`: presses a menu-bar item through accessibility. Each level
  matches exactly, else by a unique prefix, else a unique substring; a miss lists what's there. A
  background app's menus are only updated when opened, so an item they show disabled is run by its
  shortcut if it has one. Services (which hand data to other apps) are refused
- `fill {fields: [{element, text} | {element, option} | {element, checked}], submit?: true | element}`:
  a whole form in one action. Text fields are cleared first unless `clear: false`
- `select {element, option}`: picks a pop-up, menu button or combo box item by title (exactly, else by
  a unique prefix or substring), through accessibility. Anything else fails without being pressed
- `navigate {url, new_window?}`: in a browser, `cmd+l`, the address, Return, then waits for the page
  to load. In a window the agent didn't open, it opens its own first, so your tabs are left alone
- `open {url|path, app?}`: opens a link, document or app the way a double-click would, without
  bringing it forward, and moves the batch to the window it opens. Only `http(s)`/`mailto` links and
  documents: apps by name are fine, but scripts, installers, other links (`shortcuts://`, `tel:`, …)
  and documents given to a terminal or script runner (`app: "Terminal"`) are refused
- `wait_for {text, role?, gone?, timeout_ms?}`: until an element showing that text (and role) is in
  any of the app's windows, or with `gone` until none is. Default 5 s, at most 30 s
- `clipboard {}` reads the clipboard into the result (after a copy); `clipboard {text}` puts text on it
  to stay. `paste {text}` pastes at the focus and puts back what was on the clipboard
- `set_value {element,text}`, `focus {element}`, `activate {}`, `close_window {}`
- `perform {element, name}`: an accessibility action with no pointer needed: `expand`, `collapse`,
  `increment`, `decrement`, `showmenu`, `scroll_to_visible`, `confirm`, `cancel`, `raise`, or any AX
  action name. An unsupported name fails with the actions the element does support
- `macro {name, vars?}`: replays a saved macro (see [Macros](#macros))
- `wait {ms}`, only for something slow (a page load, a search). `act` already waits for the window to
  settle after each batch.

An element behind an open sheet or modal dialog can't be pressed, set or focused, just as a person
couldn't click it: the action fails and names the sheet's buttons.

## Naming elements

`target` is the text an element shows (its title, label, value or help), matched case-insensitively,
whole words first: `"Save"`, or `{"text": "Save", "role": "button", "nth": 2}`. It's searched for in the
window and in its app's sheets, popovers and menus over it, when the action runs. A control beats a
bare label saying the same thing. If more than one element is left, the action fails and names them,
numbered, so the next call can pick one:

```
error: action 1 (click): "OK" matches 2 elements: [31] button "OK" at (412,380); [44] button "OK" at (412,610). Name one by its number, or add role or nth
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
compare with. If puter-use stops in the middle of a batch, the batch isn't sent again (it may have
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
`note: now on new window #9972`. With `PUTER_USE_WINDOW_SIZE` set, it also shrinks the window and adds
`, sized to 1280x860 pt`.

The status line is all the extra context you get:

```
Firefox #244 "GitHub" · 918x756 · changed in (40,120)-(900,610)
```

"Changed" is judged against the last image the agent was shown, so after `screenshot: "never"` calls
the next image covers everything since then.

## Macros

When a batch has done a job you'll want again, run it with `save_as`. If every action succeeds, it's
saved under that name for the app (`~/Library/Application Support/puter-use/macros/<name>.json`):

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
- Each var's value becomes `{{var}}` where it appears in what the steps type, choose or open (`text`,
  `option`, `item`, `url`, …; a value under 3 characters only where it's the whole of one), to be
  filled in on replay. Replaying needs every var and takes no others. Anything else you typed is
  saved as it is, so don't save a batch that typed a secret. A `save_as` with a bad name or an empty
  var is refused before the batch runs; saving under an existing name replaces that macro.

A macro only runs in the app it was saved in (by bundle id, or by name for an app without one). `macros`
lists the window's app's, and `macros(delete=…)` removes one.

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
`screenshot()`, `outline()`, `read(region)`, `find()` and `menus()` look. Scripts run in the CLI's
session and see what it has seen. There's no MCP equivalent: an agent that can run scripts has a shell.

## Sessions

Every request names a session: `PUTER_USE_SESSION`, or by default `mcp-<pid>` for each MCP server
and `default` for the CLI. A session has its own current window, its own record of what it last saw,
its own held keys, and its own pointer, drawn in a different colour (purple, teal, orange, blue, pink)
when several are about. Requests of different sessions run side by side. One session drives an app at
a time: another's `act` on the same app waits until the first batch is done, so two agents never
interleave keys in one window. A session idle for 30 minutes lets go of its pointer and apps.
