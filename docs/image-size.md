# Image size

Claude bills an image by its dimensions: `ceil(w/28) × ceil(h/28)` tokens, and OpenAI uses 32 px
patches the same way. Format and byte size don't change the token count. So the helper picks the
smallest dimensions that keep UI text readable, and compression only keeps the payload small.

- **Scale.** 0.75 output pixels per screen point, with the aspect ratio kept. That's 0.75× a
  non-Retina screenshot and 0.375× a Retina one. Points are the same on both kinds of display, so the
  result is too.
  - 9–11 pt text (Hacker News subtext, Google Ads tables) stays legible.
  - At 0.6 it blurs, and below about 0.55 the agent has to zoom. A zoom costs a whole extra model call,
    which is far more than the tokens saved.
- **Cap.** At most 1000 tokens, about the 1024×768 that Anthropic and OpenAI recommend for computer
  use. Larger windows are scaled down further and get blurry.
- **Agent windows.** Screenshot cost grows with window area, while legibility depends on pixels per
  point. New windows the agent opens keep the size the app gives them, so a large one is scaled
  below 0.75 to fit the cap and its text gets softer (see the table). Set `PUTER_USE_WINDOW_SIZE` to
  shrink (never enlarge) them to fit a box instead.
  - 1280×860 pt is about 780 tokens at full 0.75 sharpness. 1280×1080 still fits under the cap at 0.72.
  - Your own windows are never resized.
- **Tile snap.** Dimensions are trimmed (by at most 10%) so a few stray pixels don't buy a whole extra
  row or column of tiles.
- **Reading values.** `screenshot(region=…, image=false)` returns the accessibility text in that box,
  one line per visual line, e.g. `380 points by hn_acker 7 hours ago | hide | 165 comments`. It's
  exact and costs a few dozen tokens.
- **Zoom.** `screenshot(region=…)` re-captures part of the window at up to 2 px/pt, for things the
  accessibility text doesn't cover.
- **Coordinates.** The agent clicks in the screenshot's own pixels, and the helper maps them back to
  screen points.

| window | original (≤1280×800 JPEG) | now |
|---|---|---|
| TextEdit 627×877 pt | 572×800, 609 tokens | 448×626, 368 tokens |
| Finder 967×639 pt (Retina) | 1210×800, 1276 tokens | 700×462, 425 tokens |
| Firefox window shrunk to 1280×860 pt (`PUTER_USE_WINDOW_SIZE=1280x860`) | 1191×800, 1247 tokens | 952×639, 782 tokens |
| Firefox window at 1712×1409 pt (not resized, the default) | 972×800, 1015 tokens | 918×756, 891 tokens (0.54 px/pt, soft) |

**Format.** The default `auto` sends a 256-colour palette PNG (PNG-8). UI is mostly flat colour and
anti-aliased text, so it stays sharp at a few KB. If a photo- or video-heavy window would push it past
`PUTER_USE_MAX_BYTES`, it falls back to JPEG.

- WebP is 10–40% smaller in bytes, but saves no tokens, and some harnesses don't accept it.
- JPEG's chroma subsampling blurs small coloured text.
