# puter-use act: actions

`puter-use act '<JSON list>'` runs the actions in order on the current window (`-w <id|app>` to
choose; none is needed when the first action is `open` or `navigate`), then prints one status line
and, if the window visibly changed, one image.

Aim each action with `x`,`y` (pixels in the latest full screenshot), `element` (a number from an
outline, `find` or marks), or `target`: the text the element shows, `"Save"` or
`{"text": "Save", "role": "button", "nth": 2}`, looked up when the action runs (several matches fail
with their numbers rather than guess). In live or re-rendering lists aim with `target`: numbers there
can go stale.

- `click {x,y|element|target, button?, keys?, item?}`; `double_click`, `triple_click`, `right_click`,
  `middle_click`. `keys`: held modifiers, e.g. `["shift"]`. `item`: what to choose from the menu the
  click opens (a pop-up, a context menu), `"Red"` or `"Font > Bold"`:
  `{"type":"right_click","target":"Notes","item":"Font > Bold"}`
- `move {x,y, keys?}`; `drag {path: [[x,y],[x,y],…]}`
- `scroll {x?,y?, scroll_x?, scroll_y?}`: pixels, positive = right/down; one that runs into the end
  stops there, with a note naming it
- `scroll {until, max_scrolls?, x?,y?}`: a screenful at a time until an element showing `until` (`"Load more"`
  or `{"text": "Total", "role": "button"}`) is in view, at most `max_scrolls` times (default 10, up to
  15); the note names it, numbered for `element`. With no `x,y`, it scrolls the scroll area holding the
  text (if accessibility has it), else the window's largest, else its centre. Not found, the batch stops
  there (as the last action: a note). Use it instead of a scroll and a look per screenful:
  `[{"type":"scroll","until":"Load more"},{"type":"click","target":"Load more"}]`
- `type {text, element|target|x,y?, clear?, submit?}`: into the focused field, or click the given one
  first; `clear` empties it, `submit` presses Return. `"\n"` is Return, `"\t"` Tab. Long text is
  pasted (your clipboard is restored)
- `keypress {keys, repeat?}`: `"cmd+t"`, `["ctrl","a"]`, or a sequence `"Tab Tab Return"`; `repeat` 1-100
- `key_down`/`key_up {keys}` hold keys over later actions; `hold_key {keys, ms}` (up to 10000);
  `mouse_down {x,y|element}`, `move` (drags while down), `mouse_up {x?,y?}`. Anything still held is let
  go at the end
- `menu {item: "File > Export as PDF…"}`: a menu-bar command, no pointer needed; the name alone works
  if no other command has it
- `fill {fields, submit?}`: a whole form, each field named by its label, no outline needed (`submit`:
  `true` for Return, or the button's text or number). `fields` as an object: `true`/`false` ticks or
  unticks, text is typed into a field or picks a pop-up's option; give phone numbers and IDs as
  strings; every label is looked up before anything is filled, and the form is filled top-down:
  `{"type":"fill","fields":{"Email":"ada@example.com","Country":"NZ","I agree":true},"submit":true}`.
  Or as a list, which also takes element numbers and `clear`:
  `[{"target":"Email","text":"…"},{"element":12,"option":"NZ"},{"target":"I agree","checked":true}]`.
  In a clicks-only app, use the list form (`option`) for pop-ups: the object form with text is refused
- `select {element|target, option}`: pick from a pop-up or combo box
- `navigate {url, new_window?, timeout_ms?}`: in a browser, in your own window; waits for the page to load
- `open {url|path, app?}`: a link, document or app, in the background
- `wait_for {text, role?, gone?, timeout_ms?}`: until an element showing the text appears (or goes);
  `wait_for {change: true, timeout_ms?}`: until the window looks different, then settles (a note if
  not). Default 5000 ms
- `clipboard {offset?, limit?, query?}`: print the clipboard (after a copy), 10000 characters from
  `offset` (below 0: from the end), or where `query` is in it; `clipboard {text}` puts text on it to
  stay. `paste {text}` pastes at the focus (the clipboard is restored after)
- `read {element|target|region?, offset?, limit?, query?}`: text at that point in the batch: an
  element's whole text, paged or searched as `shot --read` does, or the text in a region
  `[x0,y0,x1,y1]`; with neither, the focused text, or in a browser the whole page as Markdown (links
  and controls numbered, `[Submit](#58)`, for `element`). Never password fields
- `set_value {element|target, text}`; `focus {element|target}`; `perform {element|target, name}`: an
  accessibility action (`expand`, `collapse`, `increment`, `decrement`, `showmenu`, `scroll_to_visible`, …)
- `macro {name, vars?}`: replay a saved macro
- `wait {ms}`: a fixed pause; `activate {}`; `close_window {}` (safer than cmd+w)
- `"confirm": true` on any action the user has OK'd (a press that stops with "Ask the user");
  `"optional": true` on one aimed by `target`: skipped with a note when its target isn't there

A batch with an action key its type doesn't take, or a scroll of 0 px, runs nothing: the error names
the key and what it most likely meant.

**When it stops.** If a sheet, dialog or menu opens over the window mid-batch, the batch stops before
the next action aimed by `x,y` ("stopped before action 3 …") and shows you the new state: continue
from there (`--no-guard` turns this off). Element, keyboard and menu steps carry on. An action that
opens a new window moves the batch to it, and says so.

**What it prints.** With `--screenshot auto` (the default) an image only if the window changed, also
after a failed action or a stop for the user's OK; `never`, just the status line; `always`, an image
every time. A batch of only `read` and `clipboard` actions prints just their text. An image may leave
out a page's blank margins (`image 654x755 (blank sides trimmed)`): coordinates are still its pixels.
`(may be old)` after the size means the window's app (mainly a browser) wasn't drawing it while it was
out of view (the note says why). A
change only in a spinner or clock that keeps moving by itself isn't a change. The status line
adds where you are when it changes: `url:` (a browser's page), `focus:` (role and label, never a
value), `selected:` (the selected text and its length) and `scroll:` (`45% down`, `bottom`, …).
The window's title is followed by whose it is: `(yours)`, `(yours, used by the user)` or `(the user's)`.
