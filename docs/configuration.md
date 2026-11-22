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
