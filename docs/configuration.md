# Configuration

Settings are environment variables. For an agent, set them in the `env` of its MCP server config;
for the CLI, in your shell.

| variable | default | meaning |
|---|---|---|
| `PUTER_USE_SCALE` | 0.75 | output pixels per screen point (0.6 is leaner but blurs text under 12 pt) |
| `PUTER_USE_WINDOW_SIZE` | `1440x900` | windows the agent opens (`navigate`, `open`, Cmd+N) are shrunk to fit this (points); windows an app opens as it launches keep their size; `off` leaves them all as the app sized them |
| `PUTER_USE_MAX_TOKENS` | 1000 | image token cap, `ceil(w/tile) × ceil(h/tile)` |
| `PUTER_USE_TILE` | 28 | 28 for Claude, 32 for OpenAI models |
| `PUTER_USE_ZOOM_SCALE` | 2 | the most pixels per point a `region` zoom gets: small regions get it, bigger ones taper toward 1.5 to keep their tokens down (see [Image size](image-size.md)) |
| `PUTER_USE_MAX_WIDTH` / `PUTER_USE_MAX_HEIGHT` | unset | optional hard pixel caps |
| `PUTER_USE_TRIM_BLANK` | `1` | `0`: `act` images keep a window's blank margins (a page's empty sides and bottom) instead of leaving them out; a `screenshot` is never trimmed (see [Image size](image-size.md)) |
| `PUTER_USE_CROP_CHANGES` | `0` | `1`: when only a small part of the window changed, an `act` image shows just that part, and coordinates are that image's own pixels (see [Smaller act images](#smaller-act-images)) |
| `PUTER_USE_DETAIL` | unset | `low`: `act` images at fewer pixels per point, as few as keep the window's text about 10 px tall (see [Smaller act images](#smaller-act-images)) |
| `PUTER_USE_FORMAT` | `auto` | `auto` (palette PNG, JPEG if over budget), `png`, `jpeg` or `webp` |
| `PUTER_USE_QUALITY` | 0.8 | starting JPEG/WebP quality |
| `PUTER_USE_MAX_BYTES` | 72000 | byte budget. Claude Code caps MCP output at ~25k tokens |
| `PUTER_USE_CURSOR` | `1` | `0` hides the agent cursor (the pointer still follows its human path) |
| `PUTER_USE_CURSOR_SPEED` | `1` | pointer pace: `2` = twice as fast, `0` = jump instantly |
| `PUTER_USE_TYPING_WPM` | `280` | typing speed, with a human rhythm; `0` = as fast as possible |
| `PUTER_USE_PASTE_OVER` | `80` | text longer than this many characters (per line) is pasted instead of typed, and so is an address in a browser's address bar; `0` = always type |
| `PUTER_USE_BROWSER_PROFILE` | unset | `agent`: `navigate` uses a Firefox of the agent's own, on a puter-use profile, instead of yours; an absolute path: the same, on that profile folder (see [The agent's own Firefox](#the-agents-own-firefox)) |
| `PUTER_USE_BRING_FORWARD` | `when-needed` | `never`: puter-use never brings an app forward by itself. By default, when one of the agent's own windows has stopped drawing while covered and you've left the keyboard and mouse alone for 3 s, its app comes forward for a moment until the window draws again, then the app you were in comes back. That gives one fresh look: covered again, the window may stop drawing again; starting Firefox with `MOZ_WINDOW_OCCLUSION=0` fixes it for good (see [Keeping your Firefox's covered windows drawn](#keeping-your-firefoxs-covered-windows-drawn)) |
| `PUTER_USE_SESSION` | `mcp-<pid>` / `default` | the session requests belong to (see [Sessions](tools.md#sessions)) |
| `PUTER_USE_APP_CARDS` | `1` | `0` turns off the line about an app on the first look at it |
| `PUTER_USE_OUTLINE_CHARS` | `8000` | longest accessibility outline sent (500-40000) |
| `PUTER_USE_TRACE` | unset | a file to log every event sent and cursor frame drawn (for `scripts/check_motion.py`) |
| `PUTER_USE_TOKEN_LOG` | unset | a JSON-lines file the MCP server adds the size of every tool call to (see [Token log](#token-log)) |
| `PUTER_USE_SHOTS` | `~/Library/Caches/puter-use/shots` | where the CLI writes screenshots |
| `PUTER_USE_SCHEMA` | `full` | `thin`: a leaner `act` for the MCP server (see [Leaner MCP profiles](#leaner-mcp-profiles)) |
| `PUTER_USE_MACROS` | `1` | `0`: the MCP server leaves out macros (the `macros` tool, `save_as`) |
| `PUTER_USE_IMAGE_META` | `0` | `1`: each image in an MCP result says which window it shows and which earlier ones it supersedes |
| `PUTER_USE_IMAGE_DELIVERY` | `inline` | `hybrid`: an `act` image of an edit checked by accessibility is saved to a file instead |
| `PUTER_USE_OMIT_VERIFIED` | `0` | `1`: an `act` image of an edit checked by accessibility is left out |

## The agent's own Firefox

With `PUTER_USE_BROWSER_PROFILE=agent`, a `navigate` with no `window` (unless the agent's current window is
another browser's), or with `window: "Firefox"`, goes to a second Firefox that puter-use starts in the
background on a profile of its own, `~/Library/Application Support/puter-use/firefox`, instead of your
Firefox or your default browser. It needs Firefox installed. Off by default. The CLI and code mode use it
too when the variable is set in their shell.

What it changes:
- Your Firefox's windows, tabs and keyboard are left alone. The agent's keys never wait for your window to
  let go of Firefox's keyboard: its instance has a keyboard of its own.
- Its windows keep drawing while covered (it's started with `MOZ_WINDOW_OCCLUSION=0`, which reaches only
  that process), so their pictures stay current and their pages readable. Minimized ones still stop.
  (Your own Firefox can do the same: see [Keeping your Firefox's covered windows
  drawn](#keeping-your-firefoxs-covered-windows-drawn).)
- It has none of your saved logins, cards, history or extensions. The `user.js` puter-use writes there on
  each start turns off autofill and password saving, first-run pages, New Tab tiles and stories, the
  translation pop-up, session restore and the default-browser prompt, and opens links from other apps in a
  window of their own.

What it costs:
- Sites the agent has to be signed in to need you to sign in there once (the profile keeps it, as any does).
- A second Firefox icon in the Dock while it runs.
- What macOS keeps per app is shared with your Firefox, such as camera and microphone permission.

`windows` and replies call it `Firefox (agent)`, and that name works as a `window`. A window id still
reaches any window, your Firefox's too. As anywhere, only the windows the agent opened there are its own:
a link you open can land there when your Firefox isn't running, in a window of its own, and that window is
yours. puter-use quits it after 30 minutes with no agent using it, and when the helper quits, but never
while it has a window the agent didn't open.

**Another profile folder.** `PUTER_USE_BROWSER_PROFILE` can also be an absolute path to a folder (a
leading `~` is expanded): the agent's Firefox then runs on that profile instead, for tests or to keep it
somewhere else. puter-use writes its `user.js` into the profile, so it uses only a folder that's new,
empty or one it set up before, never a profile of yours: it says so instead of starting. Nor does it
start on a profile another Firefox is using (one whose command line names that folder, or one holding
its lock, as your Firefox holds its own profile's): it says which one, rather than leave Firefox to
complain that it's already running. While the agent's Firefox runs on one folder, a `navigate` that
asks for another says so; the other is used once it has quit.

## Keeping your Firefox's covered windows drawn

Firefox stops drawing a window that gets fully covered while it isn't Firefox's key window, and drops
its page's accessibility tree, until part of it shows again. When that happens to one of the agent's
own windows while you've left the keyboard and mouse alone for 3 seconds, puter-use brings Firefox
forward for a moment, until the window draws again (usually well under a second), then brings back the
app you were in. If you touch the keyboard or mouse meanwhile, your app comes back at once. Never while
you're in Firefox or a full-screen app, never onto another Space, and at most once a window every 30
seconds; the window may stay above other apps' windows that covered it, below the one you were in.
That gives the agent one fresh look, not a lasting fix: once the window is covered again it may stop
drawing again. The lasting fix is starting Firefox with `MOZ_WINDOW_OCCLUSION=0`, as below.
`PUTER_USE_BRING_FORWARD=never` turns that off. With it off, or when it can't (you're busy, say), puter-use
tells the agent the window isn't drawn (see "Windows that aren't being drawn" in [Tools](tools.md)): the agent then has
to ask you to bring it into view, and it's told you can stop this as below.

Your own Firefox keeps drawing its covered windows, so none of that happens, when it's started with the
environment variable `MOZ_WINDOW_OCCLUSION=0`.

1. Quit Firefox.
2. In Terminal, run `launchctl setenv MOZ_WINDOW_OCCLUSION 0`.
3. Start Firefox again (from the Dock, Spotlight or Finder).

That lasts until you log out or restart. To keep it, have a LaunchAgent run the same command at each
login: save this as `~/Library/LaunchAgents/local.moz-window-occlusion.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.moz-window-occlusion</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/launchctl</string>
        <string>setenv</string>
        <string>MOZ_WINDOW_OCCLUSION</string>
        <string>0</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

It runs from your next login on. If Firefox reopens at login before it has run, quit Firefox and start
it again. `launchctl getenv MOZ_WINDOW_OCCLUSION` prints `0` while it's set. To undo it, delete the
file, run `launchctl unsetenv MOZ_WINDOW_OCCLUSION` and restart Firefox.

What it costs: Firefox keeps drawing its covered windows, so it uses a little more CPU and battery.
Minimized windows still pause, as before. puter-use reads the variable from each Firefox process, so a
covered window of one started with it never counts as not drawn. Browsers built on Firefox (Zen,
LibreWolf, …) read the same variable. The agent's own Firefox is always started with it.

## Leaner MCP profiles

These cut what the MCP server puts in an agent's context. Each is off unless set, and with all of them
off the server's tools, instructions and results are exactly as without them. `PUTER_USE_SCHEMA` and
`PUTER_USE_MACROS` are read once, when the server starts: what a server advertises never changes
during a session, so a client's prompt cache holds. The CLI and code mode ignore all five.

- **`PUTER_USE_SCHEMA=thin`.** `act`'s schema gives each action only its `type` (every action name is
  still listed) and `x`, `y`, `element`, `target` and `confirm`, and leaves the action open to any
  other key. Its description keeps the common actions and only names the rest (`key_down`, `key_up`,
  `hold_key`, `mouse_down`, `mouse_up`, `set_value`, `focus`, `perform`, `activate`, `macro`, and
  `save_as`). What it says of those is in an MCP resource, `puter-use://docs/advanced-actions`, which
  the server lists only in this profile. About 1.8 KB less before the first call. Every action
  still takes every key it did, and a call is still checked in full: a key its action doesn't read
  stops the batch before anything runs, naming what it most likely meant. For clients that send the model plain JSON
  Schema and let it read MCP resources (Claude Code does). Not for Gemini CLI, which strips
  `additionalProperties` (an action would reach the model nearly empty) and shows resources only
  when the user adds them, nor for OpenAI's strict function calling, which refuses open objects.
- **`PUTER_USE_MACROS=0`.** No `macros` tool, and neither `act`'s schema nor its description nor the
  instructions mention macros (`save_as`, the `macro` action, `vars`): about 1.1 KB less. For agents
  that never save or replay one. A macro already saved still replays if asked for by name, and an
  app's first look still lists the ones saved for it.
- **`PUTER_USE_IMAGE_META=1`.** Each image in a result carries
  `_meta: {"puter_use": {"window_id", "seq", "kind", "supersedes_before_seq"}}`, for a client or proxy
  that drops old screenshots from the conversation. `seq` numbers a window's images, going up for the
  server's life. `kind` is `full` (the whole window, or the screen), `zoom` (`screenshot`'s `region`)
  or `crop` (an `act` image of only the part that changed, see [below](#smaller-act-images)). Every
  image of that window numbered below `supersedes_before_seq` shows nothing that this one and those
  after it don't: a `full` image's own number, else the last `full` one's (0: none). Drop them in
  batches every few turns rather than on each turn, which would cost the prompt cache more than the
  images.
- **`PUTER_USE_IMAGE_DELIVERY=hybrid`.** When the helper has checked an `act` batch's edit by
  accessibility (the text typed is there, say), its image is saved to
  `~/Library/Caches/puter-use/mcp-shots/<session>/<window>-<seq>.png` (the newest 50 kept per
  session), and the result says `image saved (the edit checked out by accessibility): <path>` in
  its place. For agents that can open an image file when something looks off. A `screenshot()` is
  always in the result, and so is the image of a batch that failed, stopped (to ask the user, or
  over something that opened), was allowed by the user, pressed something given `confirm`, or
  ended on a window or app the agent hasn't seen yet.
- **`PUTER_USE_OMIT_VERIFIED=1`.** In the same cases, the image is left out, and the result says
  `no image: the edit checked out by accessibility (screenshot to look)`. With hybrid delivery also
  set, the image is saved instead.

`act` asks the helper to check a batch's edit by accessibility (`verify_edits`) only when
`PUTER_USE_IMAGE_DELIVERY=hybrid` or `PUTER_USE_OMIT_VERIFIED=1` is set: with neither, it never asks,
and nothing is checked or said about it.

## Smaller act images

Two more settings make `act`'s images cheaper. Both are off unless set. Unlike the profiles above, they
apply to the MCP server, the CLI and code mode alike. They're read on each call, so what the MCP server
advertises stays the same. A call can also ask for either itself, and its own say wins: `act`'s
`crop_changes: true` and `detail: "low"`, the CLI's `--crop-changes` and `--detail low`, and code
mode's `pu.act(…, crop_changes=True, detail="low")`. `act`'s `crop_changes: false` or
`detail: "normal"` (in code mode, `crop_changes=False` or `detail="normal"`) turn off a setting for that
call. See [Image size](image-size.md) for what each costs and shows.

- **`PUTER_USE_CROP_CHANGES=1`.** When only a small part of the window changed (typing into a field,
  ticking a box), the `act` image shows only that part, a few tiles round the change, instead of the
  whole window. The status line gives that part's place in the window and says coordinates are the
  image's own pixels. Pixels off it are refused. A whole image still comes for:
  - the first look at a window, and every fifth image of it;
  - a new window, or one moved or resized, or a sheet or pop-up that opened or closed;
  - an error, any stop, or a press given `confirm`;
  - `screenshot: "always"`;
  - every `screenshot()`.
- **`PUTER_USE_DETAIL=low`.** `act` images are taken at as few pixels per point as keep a line of the
  window's text about 10 px tall: never below 0.5 px/pt, and never sharper than usual. The status line
  says `low detail (0.62 px/pt)`. A `screenshot` keeps the usual detail unless it's given
  `detail: "low"` itself, and a zoom (`region`) always does.

## Token log

With `PUTER_USE_TOKEN_LOG=/path/to/tokens.jsonl`, the MCP server adds a line to that file for each tool
call, to show what a session puts in the agent's context. The file's folder must exist. Logging never
changes what a call returns, and a file that can't be written is skipped. Every line has `ts` (Unix
time) and `pid` (servers side by side can share a file).

- `"event": "session"`, once per server: what it costs before any call. `instructions_bytes`,
  `tools_bytes` (each tool as advertised: compact JSON of its name, description and input schema) and
  their total, `static_bytes`.
- `"event": "call"`: `tool`, `outcome` (`ok`, `error` or `cancelled`), `ms`, and `args_bytes` (the
  arguments other than defaults, as compact JSON). `text_bytes` is the result's text, and `split`
  breaks it down into `status`, `notes`, `errors`, `card` (the line about an app), `outline` (or the
  list `find`, `menus` or `macros` return, or what can be acted on in an image of only what changed)
  and `read` (text from `read`, from `read` actions in a batch,
  or from `clipboard`). `images` has
  one entry per image: `bytes`, `format`, `w`, `h`, and `tokens`, its cost under each vendor's formula:

| key | models | formula |
|---|---|---|
| `claude` | Claude | `ceil(w/28) × ceil(h/28)` |
| `gpt_4o` | gpt-4o, gpt-4.1 | `85 + 170 × tiles`: 512 px tiles, after fitting in 2048×2048, then the short side to 768 |
| `gpt_5` | gpt-5, gpt-5.1 | `70 + 140 × tiles` |
| `gpt_5_2` | gpt-5.2 and later | `ceil(ceil(w/32) × ceil(h/32) × 1.2)` |
| `gemini_2` | Gemini 2.x | 258 within 384×384, else 258 per square crop of ⅔ of the short side |
| `gemini_3` | Gemini 3 | 1120 (default `media_resolution`) |

Text is in bytes: tokens per byte depend on the model's tokenizer.
