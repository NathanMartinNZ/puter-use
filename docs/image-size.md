# Image size

Claude bills an image by its dimensions: `ceil(w/28) × ceil(h/28)` tokens, and OpenAI uses 32 px
patches the same way. Format and byte size don't change the token count. So the helper picks the
smallest dimensions that keep UI text readable, and compression only keeps the payload small. To see
what a session's images and text actually cost, under each vendor's formula, turn on the
[token log](configuration.md#token-log).

- **Scale.** 0.75 output pixels per screen point, with the aspect ratio kept. That's 0.75× a
  non-Retina screenshot and 0.375× a Retina one. Points are the same on both kinds of display, so the
  result is too.
  - 9-11 pt text (Hacker News subtext, Google Ads tables) stays legible.
  - At 0.6 it blurs, and below about 0.55 the agent has to zoom. A zoom costs a whole extra model call,
    which is far more than the tokens saved.
- **Cap.** At most 1000 tokens, about the 1024×768 that Anthropic and OpenAI recommend for computer
  use. Larger windows are scaled down further and get blurry.
- **Agent windows.** Screenshot cost grows with window area, while legibility depends on pixels per
  point. A large window is scaled below 0.75 to fit the cap, and its text gets softer (see the table).
  So new windows the agent opens (`navigate`, `open`, Cmd+N) are shrunk (never enlarged) to fit
  1440×900 pt by default. Set `PUTER_USE_WINDOW_SIZE` to another box, or to `off` to keep the size the
  app gives them.
  - 1440×900 pt is about 910 tokens at full 0.75 sharpness. 1280×860 pt is about 780 tokens.
  - Your own windows are never resized. Nor are the windows an app opens or restores as it launches
    (they may be your last session), or a new window that appears while you're clicking or using
    shortcuts in that app (it may be yours).
  - A browser may give a new window the agent window's size if Cmd+N is pressed in it. It may also
    keep that size for its next launch if the agent's window is still open when it quits. `off`
    avoids both.
- **Tile snap.** Dimensions are trimmed (by at most 10%) so a few stray pixels don't buy a whole extra
  row or column of tiles. A side that still ends 1-6 px past a tile line is brought onto it by scaling
  the whole picture down by one factor, at most 2.5% (1% where that would take it below 0.6 px/pt),
  and only when that saves tiles: a 1728×1117 pt window comes out at 1036×669, 888 tokens instead of
  912. 1440×900 pt windows are already on the grid.
- **Blank margins.** An `act` image leaves out blank margins, which cost tokens and show nothing: a web
  page's empty sides, keeping a scroll bar at the right edge beside the content, and an empty bottom.
  A side has to be at least 12% of the width (the bottom 20% of the height), and the cut has to save at
  least a tenth of the image's tokens. A news article in a 1280 pt wide Firefox window drops from
  952×755 (918 tokens) to about 654×755 (648); a sparse page loses most of its picture. The status line
  says `(blank sides trimmed)` after the size, and coordinates stay the image's own pixels. A
  `screenshot` and a zoom are never trimmed. `PUTER_USE_TRIM_BLANK=0` turns it off.
- **Only what changed (opt-in).** With `PUTER_USE_CROP_CHANGES=1`, or `act`'s `crop_changes: true`, an
  `act` image shows only the part of the window that changed, when that's small: whole tiles round the
  change, with room round it (24 pt, a tile at least), at least four tiles a side. The change has to
  cover at most a quarter of the picture, and the crop has to save at least half its tokens; a small
  window is sent whole. Typing into a field of a 1440×900 pt window costs about 16 tokens instead of
  912. The status line gives the part's place in the window, in points:

  ```
  Probe #7 "w" · image 112x112 (showing only the changed area, window points (0,0)-(151,151): coords are this picture's own pixels; screenshot for the whole window) · changed in (11,33)-(40,45)
  ```

  Coordinates, and the `changed in` box, are that image's own pixels: the helper maps them back to the
  window. Pixels off it, such as ones read off an earlier whole image, are refused, and the error says how
  to aim instead. `target` and `element` aim as ever. Without marks or an outline, the result also numbers
  what can be acted on in that part, for `element`. A whole image still comes for:
  - the first look at a window, and every fifth image of it (after four crops in a row);
  - a new window, or one moved or resized, or a sheet or pop-up that opened or closed;
  - an error, any stop (the guard, a macro's positions, the user's OK), or a press given `confirm`;
  - the outline falling back to a picture, or `screenshot: "always"`;
  - every `screenshot()`.

  Take a `screenshot` to see the whole window at any time. A crop is never trimmed, nor kept out of a
  result by hybrid delivery or `PUTER_USE_OMIT_VERIFIED`. With `PUTER_USE_IMAGE_META=1` it's tagged
  `kind: "crop"`.
- **Low detail (opt-in).** `detail: "low"` on `act` or `screenshot`, or `PUTER_USE_DETAIL=low` for every
  `act` image, takes the picture at as few pixels per point as keep a line of the window's text 10 px
  tall. That's judged by the height accessibility gives its texts (the median; a web page's own, if
  smaller). It never goes below 0.5 px/pt, nor sharper than usual. Where the text's height isn't known
  (the screen, or an app whose accessibility tree isn't on yet), it uses 0.65 px/pt. A 1440×900 pt
  window with 13 pt text comes out at 896×560 (640 tokens) instead of 1064×665 (912). The status line
  says `low detail (0.62 px/pt)` (`of a 1440x900-pt window` too, right after an image at the usual
  detail), and coordinates are that image's own pixels. A zoom keeps its own scale.
- **Reading values.** `screenshot(region=…, image=false)` returns the accessibility text in that box,
  one line per visual line, e.g. `380 points by hn_acker 7 hours ago | hide | 165 comments`. It's
  exact and costs a few dozen tokens. A text area in the box gives only the lines it shows there, and
  the text stops at 8,000 characters, with a note pointing to `read` for a text area's whole text.
- **Zoom.** `screenshot(region=…)` re-captures part of the window, for things the accessibility text
  doesn't cover. A small region (up to about 220×140 pt) gets the full 2 px/pt (`PUTER_USE_ZOOM_SCALE`).
  Bigger ones taper to 1.5 px/pt by 400×250 pt, which still draws 8 pt text 12 px tall, and a large
  one is brought down toward about 600 tokens, never below 1.4 px/pt. A 296×185 px region of a
  1440×900 pt window comes back at 582×364 (273 tokens; it was 761×476).
- **Coordinates.** The agent clicks in the screenshot's own pixels (the status line's `image 1064x665`),
  and the helper maps them back to screen points. An image of a window at another scale than the last
  one the agent was shown adds the window's size, so the window doesn't seem to change size:
  `image 922x756 (0.64 px/pt of a 1448x1187-pt window)`. `windows` gives sizes in points.
- **Fewer images.** An `act` sends no image when nothing visibly changed, and neither a blinking text
  cursor nor something that keeps moving by itself (a spinner, a clock) counts as a change (see
  [Tools](tools.md)). Opt-in, for the MCP server: `PUTER_USE_OMIT_VERIFIED=1` leaves out the image of
  an `act` whose edit the helper checked by accessibility, `PUTER_USE_IMAGE_DELIVERY=hybrid` saves it
  to `~/Library/Caches/puter-use/mcp-shots/<session>/` instead, and `PUTER_USE_IMAGE_META=1` tags each
  image with `_meta` so a client can drop the ones a newer image supersedes. See
  [Leaner MCP profiles](configuration.md#leaner-mcp-profiles).

| window | original (≤1280×800 JPEG) | now |
|---|---|---|
| TextEdit 627×877 pt | 572×800, 609 tokens | 448×626, 368 tokens |
| Finder 967×639 pt (Retina) | 1210×800, 1276 tokens | 700×462, 425 tokens |
| Firefox window shrunk to 1440×900 pt (the default) | 1280×800, 1334 tokens | 1064×665, 912 tokens |
| Firefox window shrunk to 1280×860 pt (`PUTER_USE_WINDOW_SIZE=1280x860`) | 1191×800, 1247 tokens | 952×639, 782 tokens |
| Firefox window at 1712×1409 pt (not resized, `PUTER_USE_WINDOW_SIZE=off`) | 972×800, 1015 tokens | 918×756, 891 tokens (0.54 px/pt, soft) |

**Format.** The default `auto` sends a 256-colour palette PNG (PNG-8). UI is mostly flat colour and
anti-aliased text, so it stays sharp at a few KB. If a photo- or video-heavy window would push it past
`PUTER_USE_MAX_BYTES`, it falls back to JPEG.

- WebP is 10-40% smaller in bytes, but saves no tokens, and some harnesses don't accept it.
- JPEG's chroma subsampling blurs small coloured text.
