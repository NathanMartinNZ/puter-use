# Configuration

Settings are environment variables. For an agent, set them in the `env` of its MCP server config;
for the CLI, in your shell.

| variable | default | meaning |
|---|---|---|
| `PUTER_USE_SCALE` | 0.75 | output pixels per screen point (0.6 is leaner but blurs text under 12 pt) |
| `PUTER_USE_WINDOW_SIZE` | `off` | e.g. `1280x860`: windows the agent opens are shrunk to fit this (points) |
| `PUTER_USE_MAX_TOKENS` | 1000 | image token cap, `ceil(w/tile) × ceil(h/tile)` |
| `PUTER_USE_TILE` | 28 | 28 for Claude, 32 for OpenAI models |
| `PUTER_USE_ZOOM_SCALE` | 2 | pixels per point for `region` zooms |
| `PUTER_USE_MAX_WIDTH` / `PUTER_USE_MAX_HEIGHT` | unset | optional hard pixel caps |
| `PUTER_USE_FORMAT` | `auto` | `auto` (palette PNG, JPEG if over budget), `png`, `jpeg` or `webp` |
| `PUTER_USE_QUALITY` | 0.8 | starting JPEG/WebP quality |
| `PUTER_USE_MAX_BYTES` | 72000 | byte budget. Claude Code caps MCP output at ~25k tokens |
| `PUTER_USE_CURSOR` | `1` | `0` hides the agent cursor (the pointer still follows its human path) |
| `PUTER_USE_CURSOR_SPEED` | `1` | pointer pace: `2` = twice as fast, `0` = jump instantly |
| `PUTER_USE_TYPING_WPM` | `140` | typing speed, with a human rhythm; `0` = as fast as possible |
| `PUTER_USE_PASTE_OVER` | `100` | text longer than this many characters (per line) is pasted instead of typed; `0` = always type |
| `PUTER_USE_SESSION` | `mcp-<pid>` / `default` | the session requests belong to (see [Sessions](tools.md#sessions)) |
| `PUTER_USE_APP_CARDS` | `1` | `0` turns off the line about an app on the first look at it |
| `PUTER_USE_OUTLINE_CHARS` | `8000` | longest accessibility outline sent (500–40000) |
| `PUTER_USE_TRACE` | unset | a file to log every event sent and cursor frame drawn (for `scripts/check_motion.py`) |
| `PUTER_USE_SHOTS` | `~/Library/Caches/puter-use/shots` | where the CLI writes screenshots |
