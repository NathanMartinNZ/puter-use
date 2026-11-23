# puter-use CLI reference

Every command prints a status line, and `image: <path>` when there's an image to view. Commands after
the first apply to the last window used; `-w <id|app>` switches. The exit status is 1 if an action
failed or the batch stopped early.

## Looking

- `puter-use windows [APP] [--launch]` lists the windows by app, `App: id "title" (tags)`: `yours`
  (you opened it), `used by the user` (yours, but they've been in it since), `current` (the one you're
  on), `front` (the user's top window), `keyboard` (gets its app's keys), `hidden`; `--launch` opens the
  app in the background. An app name works as the window anywhere, so this is only for choosing among
  several.
- `puter-use shot <id|app>` captures that window. Screenshots are downscaled to save context:
  coordinates are pixels in the **latest full screenshot** of that window, and the tool maps them to
  the real window.
- `shot --region x0,y0,x1,y1 --no-image` prints just the text in that box, to read exact values (a
  price, a table row). A text area gives only the lines it shows there; at most 8000 characters, then
  a note. Without `--no-image` it zooms in instead. Keep using full-screenshot coordinates afterwards.
- `shot --read Notes` (its label or number; `--read` alone: the focused one) prints the whole text of
  a text area or field instead of scrolling and looking, 10000 characters at a time: `--offset 10000`
  for the next part, `--offset -2000` for the last 2000 characters. `--query invoice` lists where that
  text is in it (a line per match, `@offset: …`), to read on from with `--offset`. In a browser,
  `--read` alone prints the whole page as Markdown, links and controls numbered (`[Submit](#58)`):
  `click -e 58` works straight away, scrolling to it first.
- `puter-use find "Export" [--role button]` lists the elements showing that text, numbered, with
  positions; `find Email Password "Sign in"` looks for several at once, and `find --role field` lists
  the fields.
- `puter-use menus [query]` lists the app's menus with their items and shortcuts (a submenu as its
  count and the items in it with a shortcut); a query searches every level and prints full paths.
  Look for a menu command before hunting through the UI: menu items and shortcuts work without aiming.
- Outlines, only when you need them (dense forms, or a click that keeps missing): `--interactive`
  adds a numbered outline of what can be acted on (`#12 button "Save"`, fields named by their labels,
  with headings, dialogs and alerts); `--text` lists everything, to read a page's text (up to ~2k
  tokens). `shot --no-image --interactive` gives the outline alone; after that, `--text` on an action
  prints only what changed. `shot --marks` draws the numbers on the controls in the image instead.
  `click -e 12` and `set 12 "…"` then work without pixel guessing.

## Acting

- `puter-use click X Y` (`--right`, `--middle`, `--double`, `--triple`, `--mods cmd`), `click -e N` for
  element N, `click -e Save` for the element showing "Save". `--item "Font > Bold"` chooses from the
  menu the click opens (a pop-up, or a context menu with `--right`) in the same step. A menu is never
  left open between calls (it would take the user's typing): one left open is closed, and the note
  lists its items.
- `puter-use type "text"` types into the focused field; `type "Ada" -e Name --clear --submit` clicks
  the Name field, empties it, types and presses Return.
- `puter-use key cmd+l` (also `Return`, `Tab`, `Escape`, `BackSpace`, `Down`, `cmd+shift+t` …), or a
  sequence: `key "Tab Tab Return"`, `key Down --repeat 5`. Use shortcuts freely (cmd+l focuses the
  address bar, cmd+t opens a new tab, …); `menus` shows an app's own.
- `puter-use menu "File > Export as PDF…"` runs a menu command (`menu "Export as PDF…"` too, if no other
  command has that name).
- `puter-use select Color Blue` picks Blue in the pop-up showing "Color" (`select N Blue`: in pop-up N).
- `puter-use fill Email=ada@example.com Size=L "I agree=true" --submit` fills a form by its labels:
  `true`/`false` ticks a checkbox, other text is typed or picked from a pop-up. Every label is looked up
  before anything is filled, and the form is filled top-down. `--submit` alone presses Return;
  `--submit Send` presses that button.
- `puter-use navigate example.com` browses in your own browser window, and puter-use switches to it.
- `puter-use open PATH|URL [--app App]` opens a document, link or app in the background.
- `puter-use wait-for "Done"` waits until text appears (`--gone` until it goes; `--change` until the
  window changes; `--timeout-ms`). Each command already waits for the window to settle: wait only for
  something slow, like a page load or a search.
- `puter-use scroll X Y --dy 600` (pixels, positive = down; `--dx` right). One of them is needed.
- `puter-use scroll --until "Load more"` scrolls a screenful at a time until it's in view (`--role
  button`, `--max-scrolls 15`; default 10) and names it, numbered. Not found, it says how far it got
  and exits 1. Better than a scroll and a look per screenful.
- `puter-use drag X1 Y1 X2 Y2 [X3 Y3 …]`
- `puter-use set Name "text"` replaces the value of the field showing "Name" (or of element N).
- `puter-use perform N expand` runs an accessibility action on element N (`collapse`, `increment`,
  `decrement`, `showmenu`, `scroll_to_visible`, …) without aiming the pointer.
- `puter-use act '[…]'` runs a batch: see [act.md](act.md). `act '[{"type":"close_window"}]'` closes
  the current window (safer than cmd+w); `act '[{"type":"clipboard"}]'` prints the clipboard after a
  copy (or use `pbpaste`).
- `puter-use release` hides the agent cursor; `puter-use quit` stops the helper (the next call starts it).

Flags on every action command: `--screenshot auto|always|never` (default `auto`: an image only if the
window changed; `never` skips it when you'll look later anyway, and the next image then shows
everything since the last one you saw), `--settle-ms`, `--no-guard`, `--confirm` (the user has OK'd
this press), `--fg` (raise the app and use the real cursor: warn the user first), `--text`,
`--interactive`, `--marks`, `--crop-changes` (when little changed, the image shows only that part: its
own pixels are the coordinates, and `shot` shows the whole window), `--detail low` (a sparser image that
keeps text readable; `shot` takes it too).

Prefer naming elements by their text (`-e Save`, `"target": "Save"` in act JSON) over coordinates.
Input is human-paced: the pointer travels to each target (0.14-0.85 s) and text is typed at about 280
WPM (over 80 characters, or an address in a browser's address bar, is pasted), so batch steps into one
`act` rather than making more calls.

## Macros

Add `--save-as NAME` to the `act` that does a job that may be wanted again (`--var file=q3.pdf` makes
that value a slot, `--describe` says what it does); it's saved only if every action succeeds. Don't
re-run a finished job to save it. Afterwards `puter-use macro NAME file=q4.pdf` replays it in one step.
The `about this app:` line names an app's macros, and `puter-use macros` lists them in full
(`--all`: every app's; `--delete NAME`): check before working something out again.

## Scripts

`puter-use exec script.py` (or `exec -c '…'`, or `exec -` for stdin) runs Python with `pu`, a
`puter_use.api.Computer`, ready; `-w` sets the window it starts on, and arguments after the script go
to `sys.argv`. Each method is one act that waits for the window to settle: `pu.click`, `type`, `key`,
`menu`, `select`, `fill`, `scroll`, `wait_for`, `navigate`, `open`, `macro`, `clipboard`, or
`pu.act([...])` for a batch. `pu.screenshot()`, `outline()`, `find()`, `menus()` and `read()` look:
`read([x0, y0, x1, y1])` is the text in a box, `read("Notes")` a text area's whole text (`offset`,
`limit`, `query` as `--read` takes them). `pu.fill({"Email": …, "I agree": True})` fills by labels, and
`pu.scroll(until="Load more")` scrolls until it shows. A failed action (or a scroll whose text never
shows) raises `ActionError`; `confirm=True` on a press the user OK'd.

## Sessions

Several agents can work at once: set `PUTER_USE_SESSION` to a name of your own so you get your own
current window and pointer.
