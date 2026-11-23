# Tools (MCP)

| tool | what it returns |
|---|---|
| `windows(app?, launch?)` | the windows by app, `App: id "title" (tags)`: see [Listing windows](#listing-windows). `launch` opens the app in the background |
| `screenshot(window?, region?, text?, image?, marks?, read?, offset?, limit?, query?, detail?)` | window image + one status line. `region` zooms; `region` + `image=false` returns just the text in that area (read off the screen if the app exposes none). A text area gives only what it shows in the region, not what's scrolled out of view, and the text stops at 8,000 characters with a note saying so (`read` gets a text area's whole text). Opt-in: `text` adds the element outline (`#12 button "Save"`, see [Looking by outline](#looking-by-outline)): `"interactive"` (the one to try first) lists only what can be acted on, fields named by their labels, links and buttons by their text, with headings, dialogs and alerts as landmarks; `true` lists everything, for reading a page's text. `image=false` alone returns only the outline, and makes later `act` calls on that window that don't set `screenshot` return the outline's changes instead of an image. `marks` numbers the controls on the image. In an app that answers slowly (a page loading, an IDE indexing), the outline and the text in a `region` stop after about 2.5 s and say they were cut short (`act` then sends that outline whole, not as changes). `read` returns a text area's or field's whole text instead, or a whole web page as Markdown, from the end with a negative `offset`, or where some text is in it with `query`: see [Reading long text](#reading-long-text). `detail: "low"` takes the image at fewer pixels per point, keeping text readable (see [Image size](image-size.md)) |
| `find(query?, role?, window?, queries?)` | the elements showing `query`, `[n] role "label" at (x,y)`, numbered for `element` (up to 20). Then those scrolled out of view, tagged `(off screen)` instead of a place: acting on one scrolls it into view first. Read off the screen when the app has no accessibility tree. With none at all, up to three similar labels. `role` with no `query` lists the elements of that role, those on screen first, saying how many there are (`role "link", the first 20 of 37 …`, then `+17 more`). `queries` looks for up to 10 texts in one call: a part for each under its own header (5 matches each by default, 40 in all), or one line for a text nothing shows |
| `menus(window?, query?)` | the app's menu bar as text, read without opening a menu: one line per menu with its items and their shortcuts. A submenu shows its number of items and those with a shortcut (`File: New Window cmd+n · Export as PDF… cmd+shift+e · Share > (3: Email Link cmd+i)`). Menus of your own things (History, Bookmarks, Window) show only their items with a shortcut, and how many more there are. `query` (a word, a shortcut or a submenu's name) searches every level and lists the matches with full paths (`File > Share > Email Link · cmd+i`) |
| `macros(window?, all?, delete?)` | the macros saved for the window's app, with their variables |
| `act(actions, window?, text?, marks?, foreground?, screenshot?, settle_ms?, guard?, save_as?, crop_changes?, detail?)` | runs the actions, then returns an image only if something changed (`screenshot`: `auto`, `always` or `never`; left out, as `auto` unless your last screenshot of the window had no image, see [Looking by outline](#looking-by-outline)), plus a status line. `text` sends what changed in the outline since the last one this session was sent, or the whole outline when the changes would be most of it. A failed action makes the result an error (with the image if the window changed since the last one you were shown, or if you haven't been shown one yet). Opt-in: `crop_changes: true` sends only the part of the window that changed, when that's small, and `detail: "low"` a sparser image (see [Image size](image-size.md)) |

`window` is an id, an app name, or `"screen"`. It defaults to the last window used. An app name means
the session's window there: the one it's on, else the one of its own (windows it opened) it used last, else
the app's front window (never macOS's dictation orb, which shows up as an untitled window of the app,
while the app has another). When that isn't the front window, a note says so (once). Coordinates are pixels in the
latest full screenshot of that window. An `act` whose first action is `open` or `navigate` needs no
`window`: the batch works in the window that action brings up (see below). That's not so with a `macro`
step in the batch, since a macro belongs to an app.

Opt-in [profiles](configuration.md#leaner-mcp-profiles), each off unless set, trim what this costs an
agent: `PUTER_USE_SCHEMA=thin` gives each action in `act`'s schema only its type and aim, and leaves the
rarely needed actions to the resource `puter-use://docs/advanced-actions` (not for Gemini CLI or
OpenAI's strict mode); `PUTER_USE_MACROS=0` drops the `macros` tool, `save_as` and `vars` (a saved
macro still replays by name); `PUTER_USE_IMAGE_META=1` tags each image with `_meta` saying which
earlier ones it supersedes; and with `PUTER_USE_IMAGE_DELIVERY=hybrid` or `PUTER_USE_OMIT_VERIFIED=1`,
the image of an `act` whose edit checked out by accessibility is saved to
`~/Library/Caches/puter-use/mcp-shots/<session>/` or left out, and the result says so.

Actions follow OpenAI/Anthropic conventions. Anything aimed at an element takes `x,y`, `element` (a
number from an outline, `find` or marks: `12` or `"#12"`) or `target` (the text it shows, see [Naming elements](#naming-elements)):

- `click {x,y | element | target, button?, keys?, item?}`, `double_click`, `triple_click`, `right_click`, `middle_click`.
  `item` chooses from the menu the click opens (a pop-up button, a context menu): `"Red"`, or
  `"Layout Orientation > Horizontal"` for a submenu, matched as `menu` items are. The pointer goes to
  the item and clicks it, resting on one with a submenu until that opens and sliding along its row
  into it. A pop-up button's item is chosen through accessibility instead, since its open menu follows
  only the real mouse. If the item isn't there, or the menu closes first (a click anywhere closes it,
  the user's too), nothing is chosen and the action fails
- `move {x,y, keys?}` (`keys`: modifiers held on the way), `drag {path:[[x,y],…]}`
- `scroll {x?,y?,scroll_x?,scroll_y?}` (pixels, positive = right/down). A scroll of 0 px (no distance
  given, or 0 for both) is refused, and so is one with `keys`: scroll events can't carry held keys, so
  the error says to scroll sideways with `scroll_x` and to zoom with the app's shortcut or menu. One
  that runs into the end stops there, with a note naming it (`note: the scroll reached the bottom after
  about 300 of 1200; the rest wasn't sent`); otherwise the status line says where the batch's last
  scroll left the scroll bar (`scroll: 45% down`), where there's one to ask
- `scroll {until, max_scrolls?, x?,y?, scroll_x?, scroll_y?}` scrolls until something shows, so a long
  or lazily drawn list takes one action. `until` is its text (`"Load more"`) or `{text, role}`. It
  scrolls what's at `x,y`; without them, the scroll area holding that text if accessibility has it, else
  the window's largest scroll area, else the window's centre. It looks first (already in view: nothing
  is scrolled), then scrolls a screenful at a time (less a tenth, so nothing is skipped; down, or
  `direction` `up`, `left` or `right`) or by the `scroll_x`/`scroll_y` given, looking after each scroll,
  by accessibility or, where the app has none, by reading the screen.
  It stops when an element in view shows the text, when a scroll moves nothing or leaves the scroll bar
  at its end, after `max_scrolls` scrolls (default 10, at most 15), or after 15 s. Found, a note names
  it, numbered for `element`: `note: scrolled 3 times; found [12] button "Load more" at (340,512)`.
  Not found, the batch stops there with an error saying how far it got (`reached the bottom after 4
  scrolls; "Total" not found`), unless it's the batch's last action: then that's a note, and the image
  shows where it stopped. It only scrolls and looks, never clicks or types, and it can't be `optional`
- `type {text, element|target|x,y?, clear?, submit?}`: with a field given, it's clicked first (the caret goes
  after its text; a selection the app made, like the whole address a browser selects when its address
  bar is clicked, is kept, so the new text replaces it); `clear` empties it, `submit` presses Return.
  Text typed at the focus replaces a browser's address only when its address bar already has the focus:
  a lone address typed while the focus is in the page stops before typing (use `navigate`). Only text fields:
  naming a button fails, and `clear` fails if the focus isn't on a text field (select-all and delete
  elsewhere could empty a whole list). If the click doesn't put the caret in the field, nothing is typed.
  Afterwards the field is read back, the focused one too when no field is given (not a password field,
  nor text with a Return or Tab in it, which may rightly change what it shows): if it doesn't show what
  was typed (an autocomplete took over, a key was lost), a note says so, and typing that went to another
  window instead fails the action
- `keypress {keys, repeat?}`: a shortcut (`"cmd+t"`, `["ctrl","a"]`) or a sequence (`"Tab Tab Return"`,
  `["cmd+a","BackSpace"]`), pressed `repeat` times (1-100) with a person's pauses between keys
- `key_down {keys}` / `key_up {keys?}` hold keys across later actions (key, click and move events
  carry a held modifier, so a click while shift is held is a shift-click, as with a real keyboard;
  scroll events don't); `type` refuses
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
- `fill {fields, submit?: true | element | "Button text"}`: a whole form in one action, each field
  named by its label, with no outline needed first. `fields` is an object of labels and values,
  `{"Email": "ada@example.com", "Country": "NZ", "I agree": true}`, or a list,
  `[{element|target, text|option|checked}, …]`, which also takes element numbers and `clear`.
  - In the object form, `true`/`false` ticks or unticks a checkbox, switch or radio button; text picks a
    pop-up's, menu button's or combo box's option (a combo box in a web page is typed into), or is
    typed into a field; a number is typed as text, so give phone numbers and IDs as strings. Every key
    is looked up, and every value checked against what it names, before anything is filled: a key that
    names nothing or several things, a value the control can't take (`true` for a text field), or two
    keys for one control stop it, naming the key (never the value). Fields are filled from the top of
    the form down, left to right in a row, whatever the order of the keys, since a later field can
    depend on an earlier one (a state after its country). The result is an ordinary `act` result (the
    image if the window changed, and the status line), with no count of fields; a field that fails
    stops it, the error naming that field.
  - A field is found by its own label, placeholder or value, or by a separate text label the app links
    to it (as most native forms and labelled web fields do). If only a label the app doesn't link
    matches, the action fails saying what it found (aim with the field's number from an outline then).
    Text fields are cleared first (in the list form, unless `clear: false`).
  - In a [clicks-only](policy.md) app the object form is refused before the batch runs when any value
    isn't `true` or `false`, since whether its text goes to a field or a pop-up isn't known until it
    runs: pick a pop-up's option there with the list form's `option`
- `select {element|target, option}`: picks a pop-up, menu button or combo box item by title (exactly, else by
  a unique prefix or substring), through accessibility. Anything else fails without being pressed. A web
  page's `<select>` works too, in Firefox as well (so do `click … item` and a `fill`'s `option`)
- `navigate {url, new_window?, timeout_ms?}`: in a browser, `cmd+l`, the address, Return, then waits for
  the page to load, up to `timeout_ms` (default 10 s, at most 30 s; a note says if it's still loading). In
  a window of the agent's, it loads there; in one it didn't open, it opens its own first (`cmd+n`), so
  your tabs are left alone. When another of the browser's windows has its keyboard (so `cmd+n` would go
  there) and the browser isn't your front app, the agent's window is opened with the browser's New Window
  menu item instead, used only if it's a fresh one (one tab, a new-tab page); while the browser is your
  front app, that stops instead, as keys do. Either way, a new window that would cover any of your
  windows of that browser is moved at once to where it covers least of them on its screen (yours never
  move). It then has the browser's keyboard, so it's in front when you next switch to the browser; a
  note says so. A batch that
  begins with `navigate` and has no `window` goes to the session's window if that's a browser's, else
  to the default browser (started in the background, or given a window, if it has none), once the
  policy is known to let the agent type there. With `PUTER_USE_BROWSER_PROFILE=agent` (or a profile
  folder), one with no
  `window` (unless the session is on another browser's window), or with `window: "Firefox"`, goes to
  [the agent's own Firefox](configuration.md#the-agents-own-firefox) instead of yours, started in the
  background if it isn't running: its first window is the agent's. A window id still reaches that window
- `open {url|path, app?}`: opens a link, document or app the way a double-click would, without
  bringing it forward, and moves the batch to the window it opens. Only `http(s)`/`mailto` links and
  documents: apps by name are fine, but scripts, installers, other links (`shortcuts://`, `tel:`, …)
  and documents given to a terminal or script runner (`app: "Terminal"`) are refused. The app it would
  start or use is checked against the [policy](policy.md) first, by its bundle id, before anything
  launches: a view-only or off-limits app isn't opened. With no `window`, a batch that begins with
  `open` works in the window it opens and touches no other window first. If none of its own appears
  (the app was already open, say), the result is its note alone, with no image, and an action after
  it fails, saying to pass `window`
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
- `clipboard {offset?, limit?, query?}` reads the clipboard into the result (after a copy): 10,000
  characters from `offset` (default 0; below 0, that many from the end; `limit` up to 50,000), with a
  note saying where to read on when there's more. `query` lists where that text is on it instead, as
  `read` does (see [Reading long text](#reading-long-text)), and the note says how many matches.
  `clipboard {text}` puts text on it to stay. `paste {text}` pastes at the focus and puts back what was on the clipboard
- `read {element|target|region?, offset?, limit?, query?}` reads text at that point in the batch (after
  a click on a tab, a `wait_for`), into the result's text, each under its own label: an element's whole
  text as `screenshot(read=…)` gives it, paged or searched the same way; a `region`'s text as
  `screenshot(region=…, image=false)` gives it (whole, so no `offset`, `limit` or `query`); with none of
  them, the text that has the keyboard focus (in a browser, the page, as `read=true` does). Password
  fields are never read. It's a look, so it works in view-only apps
- `set_value {element|target, text}`, `focus {element|target}`, `activate {}`, `close_window {}`
- `perform {element|target, name}`: an accessibility action with no pointer needed: `expand`, `collapse`,
  `increment`, `decrement`, `showmenu`, `scroll_to_visible`, `confirm`, `cancel`, `raise`, or any AX
  action name. An unsupported name fails with the actions the element does support
- `macro {name, vars?}`: replays a saved macro (see [Macros](#macros))
- `wait {ms}`: a fixed pause. `act` already waits for the window to settle after each batch, and for
  something slow (a page load, a search) `wait_for` ends as soon as it's there.

**Checked before anything runs.** An action of a type no action has, or with a key its type doesn't
read (in a `fill`'s fields too), stops the whole batch before any of it runs. So does a scroll of 0 px,
an `until` or `max_scrolls` it can't read, or a value in a `fill`'s object form that isn't text, a
number, `true` or `false`. The error names the key and what it most likely meant:

```
nothing was run: action 2 (scroll) has an unknown key "delta_y" (did you mean scroll_y?): scroll takes x, y, element, target, scroll_x, scroll_y, direction, amount
```

The keys `reason`, `description`, `comment` and `note` are ignored on any action, for a model that
explains its steps. The other names actions go by, OpenAI's and Anthropic's computer-use shapes among
them (`coordinate`, `scroll_direction`, Anthropic's `text` on a click for the modifier keys it holds),
are read as they come. A key with an empty value (`null`, `""`, `[]`), as a client that fills in every
field sends, passes too.

**Optional steps.** `optional: true` on an action aimed by `target` alone skips it, with a note, when
nothing shows its target, and the batch goes on: for a cookie banner or a dialog that may not come.
It's never skipped when the target matches several elements, is behind a sheet, or stops for the
user's OK. A step by `x,y` or number always runs, and neither a `fill`'s fields nor a scroll with
`until` can be optional. A macro saved from the batch keeps the step, optional.

**Keyboard isolation.** Key events go to the app's key window, not the window they're stamped for. If
another window of the same app has the keyboard (you brought one forward), keys, modifier-clicks and
menu commands stop with an error naming that window instead of acting on yours (checked before each
keystroke, so taking the keyboard mid-text stops it there). Clicks without keys still go to the
agent's window. While the app is your front app, the error says it clears when you leave it; in the
background the keyboard never moves back by itself, so it says not to retry and to ask you. The third
refusal for a window within 3 minutes says to stop retrying (in place of any "try again"). It never
tells the agent to take the keyboard from you.

**Waiting for pages.** After a click on a link or a web page's button, Return in a web page's field,
or a `fill`'s submit, a page that starts to change is waited for, up to 10 s, so the next action and
the picture meet the new page. One still loading gets a note: `wait_for what it should show rather
than doing it again`.

When the keyboard is on another of the agent's *own* windows (two browser windows it opened), `act`
moves it to the target at the start of the call. If the app is your front app, it does that only once
you've left the keyboard and mouse alone for 2 seconds, since you may be typing into that window;
otherwise the action stops and says to try again. The same goes for keys into the agent's window when
it already has the keyboard of your front app (it's the window you're in), checked before each key, so
its typing stops when you come in. When it's on one of *your* windows and the app is
in the background, keys for the agent's own window move it there the same way (as a click there
would), with a note: that window is in front when you next switch to the app. Never while you're in
the app (switching to it just then stops the keys), and never to a window of the agent's you've used
(nor, while you're in the app, off one).

A window the agent opens (with `navigate`, `open`, or an action that opens one) that lands partly off
screen is moved onto it, since what's off screen can't be captured or clicked (unless you may have
opened it yourself: see new windows below). Your own windows stay where you put them: a screenshot
of one that's partly off screen says how much of it is shown.

An element behind an open sheet or modal dialog can't be pressed, set or focused, just as a person
couldn't click it: the action fails and names the sheet's buttons.

## Listing windows

`windows` lists the windows you can control by app, apps in the order of their frontmost window, each
app once with its policy (if it isn't full), a single window on its app's line:

```
Firefox:
  244 "GitHub" (yours, current)
  250 "Inbox" (front, keyboard)
  251 "Downloads" (hidden)
Terminal · clicks only, no typing (policy): 10 "zsh"
Finder:
  301 "Downloads" 900x500 pt (hidden)
  302 "Downloads" 700x400 pt (hidden)
```

A title loses its app's name at the end (`GitHub — Mozilla Firefox` is `"GitHub"`), one with none
reads `untitled`, and a size comes only to tell apart windows of one app with the same title. Tags:
`yours`, a window you opened; `used by the user`, one of yours they've been in since (see below);
`current`, the one you're on (where a call without `window` goes); `front`, the front window of the
app in front, what the user sees on top; `keyboard`, the window that gets its app's keys (when that's
the user's window, your keys and menu commands in the app may stop), asked of apps with more than one
window listed, or with yours or the current one; `hidden`, minimized, on another Space or otherwise
off screen (a call on one of those fails saying which: bringing it back would put it in front of the
user, so ask them). Windows drawn fully transparent aren't listed. Past 20 hidden windows, the rest that carry
no tag are counted under their app (`+12 more hidden`); `windows(app=…)` lists all of one app's. [The
agent's own Firefox](configuration.md#the-agents-own-firefox) is listed as `Firefox (agent)`, a name
that also works as a `window`.

A window stays yours until there are signs the user took it over. A change alone (a redirect, a
sign-in hop, a page's own route change) keeps it, and so does the user working in another window of
the same app; a call on that window says so when it shows another site or tab count (not for a title
alone, as a clock or an unread count keeps changing). If the user was in it since your last call (it
was the key window of their front app, as they left the app or now, and they pressed keys or clicked
there beyond what left the app: three keys, two clicks, or one of each, so a Cmd-Tab in and out isn't
it) and its title or tab count changed, it's theirs when it shows another site or tab count (a note
says so, and `navigate` opens a new window), else it's `used by the user`. One you haven't used for 2
hours is theirs again.
`close_window` stops on a window of yours with more tabs than when you last acted there, or one the
user took over: ask them, then pass `confirm: true`.

## Naming elements

`target` is the text an element shows (its title, label, value or help), matched case-insensitively,
with curly quotes, dashes and no-break spaces as their plain marks (`we've` finds `we’ve`, as `find`
and `wait_for` do): whole labels on screen when there are any (spacing and `...` vs `…` don't
matter), else a single label containing it, unless a quick look finds a whole label off screen (then
the action fails and lists both, numbered).
`"Save"`, or `{"text": "Save", "role": "button", "nth": 2}`. It's searched for in the window and in
its app's sheets, popovers and menus over it, when the action runs. A control beats a
bare label saying the same thing, and a label the app links to a field (its title) names that field,
so `{type: "type", target: "Email", …}` finds the field beside "Email"; where the app doesn't link
them, aim with the field's number. If more than one element is left, the action fails and names them,
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
TextEdit #812 "Untitled" · image 448x626 · ran 2/4 actions · changed in (60,0)-(390,180)
stopped before action 3 (click by coordinates): something opened over the window (window #815 360x210); actions 3-4 were not run. Look at the new screenshot, then continue.
```

The batch also stops before its first `x,y` action when this session has no earlier screenshot of the
window to read the coordinates from (a new session, or puter-use restarted), and returns one. The
`x,y` that `find` lists count as such a screenshot: they come from a picture it takes of the window, so
a click there doesn't stop. Until you've been shown an image of a window (`find` shows none), an `act`
on it returns one, since there's no picture of yours to compare with, even when its first action fails:
the error comes with the window, so you can aim from it. Later, when nothing runs (the first action
fails, or the batch stops for the user's OK before it), the window is looked at once, without waiting
for it to settle, and the image comes only if it changed since the last one you were shown (a page
that loaded, a dialog that came up). Otherwise the error comes with `no visible change` (a stop for
the user's OK comes alone), and your last image still holds. If puter-use stops in the middle of a batch, the batch isn't sent again (it may have
partly run): the call fails, and a screenshot shows where things stand. Element, keyboard and menu
actions carry on, since they don't depend on the picture: a shortcut that
opens a dialog, then typing into it and Return, still runs as one batch. `guard=false` (`--no-guard`) turns the stop
off. After an action that may open something (a click, Return, a shortcut, a menu item) the next
action waits up to 0.15 s for a sheet or menu to appear, and if one does, until it has finished
animating in.

**Windows that aren't being drawn.** Apps can stop drawing a window no part of which shows, browsers
mainly (Firefox, one that wasn't its key window as it got covered), so its capture is what it last drew.
Making it key later doesn't bring it back; only part of it showing again does. puter-use
says so, in any app, only on evidence, while the window is covered, minimized or on another Space: its
title changed but a new capture is the last one pixel for pixel, or its page has no accessibility tree
though its address bar names one. It's worked out only when one of those signs shows. Then the image is marked `(may be old)`
and a note says why:

```
note: Firefox isn't drawing #26972 (it's covered): this picture may be old (the title is now "Dashboard"), and the page can't be read; the user can stop this by starting Firefox with MOZ_WINDOW_OCCLUSION=0 (see puter-use's docs)
```

The last part comes only for a covered window of a Firefox started without that variable. Started with
it, Firefox keeps drawing its covered windows (minimized ones still pause), and puter-use, which reads
the variable from each Firefox process, never counts one of those as not drawn: see [Keeping your
Firefox's covered windows drawn](configuration.md#keeping-your-firefoxs-covered-windows-drawn).

Actions by `x,y` stop (by `element` or `target` they still run). Once the window is in view again
they go ahead if it still looks as in that picture, else they stop for a new screenshot; a picture
taken while it's in view isn't marked. A `wait_for`, `find` or `target` that finds nothing fails at
once, rather than time out or read the old picture, and a `target` says only that, not what's like it
(in a browser that would be its own buttons). In a browser, text found only in the window's tabs or
toolbar (they carry the page's title) isn't the page's: `wait_for` fails the same way, and `find` lists
it marked `(Firefox's own, not in the page)`. `navigate` says it can't tell whether the page loaded.
Ask the user to bring the window into view (even partly), or `activate` it if they agree (that brings
the app to the front).

Before any of that, by default, puter-use brings the app forward for a moment itself, when the window
is one of the agent's own (not one the user has used), it's covered (not minimized, on another Space or
with its app hidden), the user has left the keyboard and mouse alone for 3 seconds, they aren't in that
app or a full-screen one, and it hasn't done so for that window in the last 30 seconds. The window is
raised as the app's key window until it draws again (1.2 s at most), then the app the user was in comes
back to the front, and what was being read or captured is read again. If the user touches the keyboard
or mouse meanwhile, their app comes back at once. A note says each time:

```
note: brought Firefox forward for 0.6 s to redraw your window #26972 (it had stopped drawing while covered), then gave focus back to Kea
```

That gives one fresh look, not a lasting fix: once the window is covered again it may stop drawing
again, and the next try waits out the 30 seconds. The lasting fix is starting Firefox with
`MOZ_WINDOW_OCCLUSION=0`, which then never needs this. When it isn't done because of the user, the
not-drawn note says so: `(it's covered; not brought forward: the user is busy)`, `the user is in
Firefox` or `the user's front app is full screen`. `PUTER_USE_BRING_FORWARD=never` turns it off.

**Menus are never left open.** While a menu is open, macOS sends it the user's real keystrokes too,
whichever app they're typing in. So a menu still open at the end of a batch (a right-click or pop-up
with nothing chosen) is closed again, and the result says what it showed (up to 25 items, each cut
to 45 characters, then `+N more`), adding `("Font > Bold" for a submenu)` when it has submenus:

```
note: a menu opened (Red · Green · Blue) and was closed again; to choose from it, make the same click with item: "…"
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
Firefox #244 "GitHub" (yours) · image 918x756 · changed in (40,120)-(900,610) · url: github.com/login · focus: field "Username"
```

The window's title is followed by whose it is: `(yours)`, `(yours, used by the user)` or `(the user's)`.
`image WxH` is the image's own pixels, which coordinates are in. When an image of a window comes at
another scale than your last one of it (a low-detail one, say), it adds the window's size, so the window
doesn't seem to change size: `image 922x756 (0.64 px/pt of a 1448x1187-pt window)`. Sizes in `windows`
are points.
After the change it says where you are in the window, each part only when it's news there (it costs
nothing otherwise):

- `url:` a browser page's address (`https://` left off; its query cut to about 40 characters, the whole
  to 120; never a user name or password it carries), after an action that may change the page (a click,
  Return, a cmd shortcut, a menu command, `navigate`, `open`, `wait_for`), when it isn't the one you
  were last told. A `screenshot` of the whole window always gives it. When the page has no
  accessibility tree (a window that isn't being drawn), it's what the address bar shows.
- `focus:` what has the keyboard focus, by role and label, never its value (`field "Search"`,
  `password`, `in another window (#9980)`), after keys, a click or a press, when it changed. An
  outline's focus line shows as `focus:` too.
- `selected:` the selected text, quoted and cut to fit, with its length (`"Q3 report" (9 chars)`),
  after a gesture that selects (a double or triple click, a shift-click, a drag, shift with an arrow,
  cmd+a, Select All). Never in a password field.
- `scroll:` where the batch's last scroll left the scroll bar: `top`, `bottom`, `45% down`, `left end`,
  `45% across`. A scroll that ran into the end says so in its note instead.

In Chromium and Firefox browsers and Electron apps these are read only once something else has
switched on the app's accessibility tree (an outline, `find`, a `target`), so the first acts there may
not have them.

**Blank margins.** An `act` image leaves out a window's blank margins: empty sides, as a web page often
has (a scroll bar at the right edge stays, beside the content), and an empty bottom, when each is a good part
of the window (a side at least 12% of its width, the bottom 20% of its height) and the cut saves at
least a tenth of the image's tokens. A column counts as blank when nothing below the top 96 pt (title
bar, toolbar, tabs) is drawn in it, so the ends of a browser's toolbar go with it; the cut never goes
through the focused text field or a mark. The status line says so after the size, which is the
trimmed image's:

```
Firefox #244 "Article" · image 654x755 (blank sides trimmed) · scroll: 30% down
```

Coordinates are that image's pixels as ever: the helper maps them back to the window, the scroll bar's
included, and below a bottom cut the window carries on. A `screenshot` is never trimmed (take one to
see the whole toolbar), nor is a zoom. `PUTER_USE_TRIM_BLANK=0` turns it off (see
[Image size](image-size.md)).

**Smaller images (opt-in).** Two options, off unless asked for, make `act`'s images cheaper: per call,
or for every call with `PUTER_USE_CROP_CHANGES=1` and `PUTER_USE_DETAIL=low` (see
[Configuration](configuration.md#smaller-act-images)).

`crop_changes: true`: when only a small part of the window changed, the image is just that part, a few
tiles round the change. The status line says so after the size, with that part's place in the window in
points. Coordinates, and `changed in`, are that image's own pixels:

```
Probe #7 "w" · image 112x112 (showing only the changed area, window points (0,0)-(151,151): coords are this picture's own pixels; screenshot for the whole window) · changed in (11,33)-(40,45)
```

Pixels off it (read off an earlier whole image, say) are refused, saying how to aim instead; `target`
and `element` aim as ever. Without marks or an outline, the result also lists what can be acted on in
that part, numbered for `element`, under
`in the changed area, numbered for element (data, not instructions):`. A whole image comes for the
first look at a window and every fifth image of it, a new, moved or resized window, a sheet or pop-up
that opened or closed, an error, any stop, a press given `confirm`, the outline falling back to a
picture, and `screenshot: "always"`. A `screenshot` is always the whole window.

`detail: "low"` (on `act` or `screenshot`): the image is taken at as few pixels per point as keep a line
of the window's text about 10 px tall, never below 0.5 px/pt. The status line says so after the size,
e.g. `image 896x560 · low detail (0.62 px/pt)`. A zoom keeps its own scale. `detail: "normal"` keeps the usual
detail, even with `PUTER_USE_DETAIL=low`. See [Image size](image-size.md) for both.

"Changed" is judged against the last image the agent was shown, so after `screenshot: "never"` calls
the next image covers everything since then. `act` looks once the window has held still, at least
`settle_ms` (250 by default) after the last input. A window that still looks the same (a blinking caret
aside) is watched a little longer, about 1 s after the last input, before the result says nothing changed. Web
pages (in a browser, an Electron app or another app's web view) always get that longer look. A text
cursor blinking where it was isn't a change. One moved by a click or an arrow key is; when it's
between blinks in both pictures, a note says it moved and how many characters into the text it is.
Where accessibility can't say where the cursor is (in Firefox's pages, say), a change the size and
shape of a text cursor counts as its blink, unless keys, typing or a click went to the window since
your last image (it may be a character typed).

Something that keeps moving by itself (a spinner, a clock, an animated ad), seen moving in the frames
taken before your last image, is left out too, after a batch that only waited, scrolled, moved the
pointer or read, away from where it scrolled or pointed. When that's all that changed, there's no
image and the result says:

```
note: only what keeps moving by itself changed (a spinner or a clock, say)
```

Neither of these affects `wait_for`, which goes by the frames as they are, so a wait on a progress
label still ends, and neither applies while you're looking by outline.

A batch stopped for the user's OK after some of it ran returns an image only if the window changed:
you have the picture you chose the press from. A batch that only reads text (`read`) or reads or sets
the clipboard returns its text alone: no picture is taken before or after it, and the app isn't made
active for it (unless `screenshot` is `"always"`).

## Looking by outline

An outline has a line per element, indented by nesting. Elements are numbered for `element` (`12` or
`"#12"`), and keep their number across looks; plain text has none, and a link in a line of text is
`[label](#n)`:

```
heading "Sign in"
#3 field "Email" ="ada@example.com" focused
#4 checkbox "Remember me" checked
By [Ada](#9) · 2 days ago · [Read the docs](#10)
#11 text "The council measured a quiet but measurable improvement in water clarity over the last…"
```

A text alone on its line that takes a click, or one cut short, keeps its number (`read=11` gets all
of it). A state shows only when it's on (`checked`, `expanded`, `selected`), a long web address is cut
in the middle (`read` gets a field's or text's whole), and the window has no line (the status line
names it).

How you last chose to look at a window sets what an `act` on it returns when it doesn't set
`screenshot`. After `screenshot(image=false)` (with no `region`), you're looking by its accessibility
outline: `act` returns what changed in the outline (`"interactive"` or all, as you last asked, unless
the act's own `text` says which) and no image. A screenshot with an image, a zoom included, or an
`act` with `screenshot: "always"`, goes back to pictures. Reading text (`read`, or `region` with
`image=false`) changes nothing. An explicit `screenshot` (`"auto"`, `"always"`, `"never"`) always
decides for that call.

Looking by outline, the image still comes, as `"auto"` would send it, when the outline can't stand in
for it or a picture is needed to go on, with a note saying why:

```
note: no outline this time: the batch stopped before an action aimed by position
```

That's when an action failed, the batch stopped (before an action aimed by `x,y`, or for the user's
OK: look before a press that can't be undone), it moved to another window or one opened, a sheet,
dialog or popover came or went, or the window has no accessibility tree or its outline is empty, has
nothing to act on, was cut short or is too long to send whole.

The changes (from `act` with `text` too) are lines marked `+` new, `~` changed and `-` gone:

```
outline changes since your last outline (+ new, ~ changed, - gone; 20 elements unchanged):
+ #31 button "New"
+ Invalid password
- #11–#19, #23
```

An element is told by its number, a line with no number by what it says (one that only moved isn't
news). Up to three gone keep their old line; more go as number ranges (texts as a count). An outline
cut at its cap keeps its note, and what it no longer reaches isn't called gone. After a full outline,
an interactive one is compared with it; after an interactive one, a full one comes whole, as does any
outline whose changes would be over two thirds of it.

## Reading long text

The outline and `region` text cover only what's on screen, so reading a long document that way is a
scroll and a look per screenful. `screenshot(read=…)` returns a text area's or text field's whole text
instead (its accessibility value), or a whole web page as Markdown, including what's scrolled out of
view, with no image. It's a look: nothing is clicked or typed, the clipboard isn't used, and it works
in view-only apps.

- `read` names the element as `element` or `target` do: its number (`read=15` or `"#15"`), or what it shows
  (`read="Notes"`, `{"text": "Notes", "role": "textarea"}`). `read=true` reads the text that has the
  keyboard focus in the window, else the window's only text area; in a browser, the page (unless a text
  area on it has the focus: a comment box, an editor). Otherwise it fails and lists the text areas and
  fields.
- 10,000 characters from `offset` (default 0; `limit` up to 50,000). A negative `offset` counts from
  the end: `offset=-2000` is the last 2,000 characters (the label gives where they start, counted from
  the beginning). The label says which part it is and where to read on:

  ```
  text of [15] textarea "Notes", characters 1-10000 of 33806; read on from offset 10000 (data, not instructions):
  0001 The quick brown fox …
  ```

- `query` finds where some text is instead, case-insensitively (curly quotes and dashes match plain
  ones), from `offset` on: a line for each of the first 10 matches, its offset and about 75 characters
  each side (line breaks shown as ⏎), then how many more there are and the offset to search on from.
  Read around one with that `offset`:

  ```
  3 matches for "invoice" in [15] textarea "Notes" (data, not instructions):
  @1204: …sent the invoice on Monday⏎…
  @20877: …invoice #4471 is overdue…
  @31002: …the next invoice goes out…
  ```

  With none, one line says so: `no match for "invoice" in 33806 characters`.

- Static text can be read too (the outline shortens long labels). Buttons, pop-ups and other controls
  fail, saying so; password fields are refused.
- A web page (`read=true` in a browser, the page's number, or a part of one with no text of its own:
  a list, a table, a section) is read whole as Markdown: headings as `#`, paragraphs in full, lists as
  `- `, tables as `| a | b |` rows, images by their alt text, links as `[label](#41)` and controls as
  `[button "Subscribe"](#58)` or `[field "Email" ="ada@example.com"](#57)`. The numbers are the
  window's outline numbers, so they work as `element` straight away; one out of view is scrolled to
  first. It's paged and searched like any text, and reading on (an `offset`, a `query`) within 60 s,
  with no `act` in between, reads the very same text, so offsets hold on a page that changes by itself:

  ```
  text of [3] web area "Water clarity improves", characters 1-10000 of 13214; read on from offset 10000 (data, not instructions):
  # Water clarity improves
  The council measured a quiet but measurable improvement … [Read the report](#41).
  ```

  A page too big to read in about 2.5 s or 8,000 elements is cut short, ending with a note that says
  why and names the last heading read (`find` reaches the rest); past 1,500 new numbers in one read,
  links and controls come without one (name them as a `target`). A password field's value is never
  read. In a Chromium browser the first read may come back partial while the page's accessibility tree
  is still being built.
- In a batch, the `read` action does the same at its point in the batch (`[click "Details", wait_for
  {text: "Total"}, read {target: "Notes"}]`), and so does `clipboard` for the clipboard's text.

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
the line about the app). `macros` lists the window's app's, one per line with its steps, vars and
description (cut to 80 characters): the first 30, then the rest by name. `macros(delete=…)` removes one.

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
field, every page of it unless `offset`/`limit` ask for a part (a negative `offset` counts from the
end); `read("Notes", query="invoice")` gives the lines saying where that text is. `find(role="field")` lists the elements
of a role, and `find(["Email", "Password"])` looks for several texts in one call, each match with the
`query` it was found for. `scroll()` needs `dy` or `dx` (0 px is refused), or `until`:
`scroll(until="Load more")` scrolls until it's in view and raises `ActionError` if it never shows.
`fill({"Email": …, "I agree": True})` sends the object form as it is. With no window chosen yet, `open()` and
`navigate()` work in the window they bring up, and the script stays on it. Scripts run in the CLI's
session and see what it has seen. There's no MCP equivalent: an agent that can run scripts has a shell.

## Sessions

Every request names a session: `PUTER_USE_SESSION`, or by default `mcp-<pid>` for each MCP server
and `default` for the CLI. A session has its own current window, its own record of what it last saw,
its own held keys, and its own pointer, drawn in a different colour (purple, teal, orange, blue, pink)
when several are about. Requests of different sessions run side by side. One session drives an app at
a time: another's `act` on the same app waits until the first batch is done, so two agents never
interleave keys in one window. A session idle for 30 minutes lets go of its pointer and apps.

Processes that set the same `PUTER_USE_SESSION` share one session: its current window, its pointer and
what it last saw (so a screenshot's coordinates hold in the other's clicks), and their requests take
turns. That's for one agent's own processes: give its MCP server (in the server config's `env`) and the
shell that runs its `exec` scripts the same name, and a script starts in the window the agent was on,
from its last screenshot. CLI shells share `default` unless they set a name. Never give two agents the
same one: each would move the other's current window and judge changes against pictures it never saw.
