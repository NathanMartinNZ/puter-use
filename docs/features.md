# Features

Everything puter-use does, in more detail than the [README](../README.md).

- **Its own cursor.** Events are delivered straight to the target app's process and window, so your
  real mouse and keyboard are never moved.
  - A purple agent cursor is drawn just above the target window, so it never covers the window you're using.
  - It moves like a hand, and the app receives that same path as mouse events. Text is typed with a
    fast typist's rhythm. See [Human input](how-it-works.md#human-input).
  - macOS shows its purple capture indicator on the window the agent is observing.
- **Small observations.**
  - Only the target window is captured, even if other windows cover it, together with its menus,
    popovers and sheets.
  - Screenshots are sized for tokens, not pixels: 0.75 px per screen point, at most 1000 image tokens,
    snapped to the model's 28 px tiles. A typical window costs 350-800 tokens and is sent as a
    5-60 KB palette PNG. See [Image size](image-size.md).
  - Windows the agent opens (e.g. a browser window from `cmd+n`) are followed automatically. They keep
    their size unless you set `PUTER_USE_WINDOW_SIZE`, which shrinks them so screenshots stay sharp.
  - To read exact values, the agent can ask for just the text in a box (`region` with `image=false`).
    That's a few dozen tokens instead of a zoomed image.
  - The agent clicks in the screenshot's own pixels, and the helper maps them to the real window.
  - After actions you get a new screenshot **only if the window visibly changed**. Otherwise you get
    one line of text.
  - The accessibility outline (`[12] button "Save"`) is opt-in (`text=true`). It's useful for dense
    forms, and elements can then be targeted by number. `text="interactive"` lists only what can be
    acted on, and after the first outline of a window `act` sends just what changed in it. `marks=true`
    draws the same numbers on the image instead.
- **Aim by what things say.** `target: "Save"` names the element showing that text. It's looked up
  as the action runs, so it can't miss when the window has shifted, and two matches fail with both
  numbers rather than a guess. `find` lists the matches. In apps with no accessibility tree (canvases,
  some games), the text is read off the screen instead.
- **Routes around the UI.** The first look at an app adds a line about it: whether it's scriptable
  (`osascript` is often quicker than clicking), its most useful shortcuts, and its quirks. The agent
  can read and set the clipboard as an action.
- **Do it again in one step.** A batch that did a job can be saved as a macro (`save_as`) and replayed
  later as one action, with variables, and with no screenshot needed. For loops and branches, a
  Python script can drive apps directly (`puter-use exec`).
- **Guard rails.** Password managers are off limits and terminals are clicks-only by default. A press
  on Delete, Send, Pay and the like waits for your OK, and nothing is typed into password fields. See
  [Policy](policy.md).
- **Several agents at once.** Each MCP server (one per agent) is its own session, with its own current
  window and its own pointer in its own colour. Sessions run side by side; two that want the same app
  take turns, a batch at a time.
- **Batched actions.** One `act` call runs several steps (click, type, keypress, scroll, drag, …)
  and returns a single screenshot at the end. A model call costs far more than an action, so the
  action set is built to let one call do more:
  - key sequences (`"Tab Tab Return"`, `repeat`), held keys and buttons;
  - compound steps: type into a field (click, clear, type, submit), fill a whole form, pick from a
    pop-up, navigate a browser, open a file, wait for something to appear;
  - menu commands by name, from a `menus` listing of every command and its shortcut;
  - a guard that stops the batch before a click aimed by coordinates once something has opened over
    the window, so a stale screenshot never clicks the wrong thing.
