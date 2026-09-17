# The temporary line's shadow — CEO item 2, 2026-09-17

> On the home screen, when one of the temporary text lines appears at the bottom of the text
> block on the right (i.e. text lines that appear and then disappear after a few seconds), it
> overlays a rectangular shadow over the entire text area and that shadow area always stays there
> afterwards which is blocking a part of the loro visual. Remove this oversized shadow overlay
> that's blocking part of the loro visual and instead of this "global overlay" that affects the
> entire text block, make it so that only the temporary text lines have a drop shadow. And make
> sure that none of that shadow is left behind after the temporary text line disappears.

Six screenshots, one page, two builds, WebKit at 1440x900 through the suite's own accessory boot
(`app/ui/tests/lib/harness.js`, the engine Tauri renders through on macOS). The `before` build is
`richos/app/ui` at `7088a57f` extracted with `git archive`; the `after` build is this branch.

| moment | before | after |
|---|---|---|
| no line has landed yet | `home-before-1-no-line-yet.png` | `home-after-1-no-line-yet.png` |
| a line is up | `home-before-2-line-up.png` | `home-after-2-line-up.png` |
| 1.2s after it has gone | `home-before-3-line-gone.png` | `home-after-3-line-gone.png` |

## What the pictures show

In `home-before-3-line-gone.png` the right third of the loro is washed out and the picture's own
`INFRASTRUCTURE 424` and `TALENT 579` captions are gone with it — the line has been off screen for
1.2 seconds. In `home-after-3-line-gone.png` that lobe and both captions are back, and there is no
trace of the line. In `home-after-2-line-up.png` the line carries a plate of its own size
(`Fathom learned from a deck · Market -> 6 new memories`) with a drop shadow on that plate, and the
picture around it is untouched.

## The same thing as a number

The shadow he saw is the renderer's quiet pass, not CSS: rectangles where the field is erased so
chrome can be read over it. `window.__loro.quietAt(x, y)` is that pass's own arithmetic. Sampled
on a 2px lattice over the right half of the viewport (720x900 = 648,000 px), area in whole pixels:

| | no line yet | line up | after it went |
|---|---|---|---|
| **before** — erased (k <= 0.01) | 57,564 | 110,928 | **123,432** |
| **before** — touched (k < 0.99) | 156,640 | 248,956 | **270,572** |
| **after** — erased | 57,564 | 57,564 | 57,564 |
| **after** — touched | 156,640 | 156,640 | 156,640 |

The `before` run ends WORSE than it was while the line was up, because a second line landed wider
than the first and the block kept the wider of the two. That is the "always stays there
afterwards" half of his sentence, measured.

## Two independent causes, both fixed

1. `home/field-engine.js`'s `computeQuiet()` carried `[$('#home-ticker')]` as its eighth quiet
   group. `landSpark` raised `quietDirty` when the line went up and nothing raised it when the line
   came down — and the line keeps its text after the fade, so a recomputed rect would have been the
   same rect anyway. The group is gone.
2. `#home-live` is absolutely positioned and therefore shrink-to-fit, and `.cap` and `#home-working`
   are blocks, so they are as wide as the aside. In flow, one long line took the aside from 201px to
   392px — the group's left edge moved 1205 -> 1014, the cap and the whole workforce list with it —
   and it never narrowed again. The line is out of flow now, so it cannot resize the block it sits
   under.

## What replaced the rectangle, and why it is not a text shadow

A `text-shadow` was tried first, because it is the literal reading of his sentence, and it was
measured rather than assumed: over the glyphs it holds, but over the LINE BOX it does not. Twelve
consecutive frames put the worst pixel at (1050, 370) — the box's top-left corner, about 3px above
the ascenders — where a bokeh lobe reads rgb(166,169,117) straight through the shadow's thin edge.
Ink 1.19-1.36:1, gold 1.00-1.03:1, every frame, against a 4.5:1 floor. A blur conserves the alpha
it spreads, so a 2px stroke blurred over 24px cannot hold the 0.85 coverage the gold needs against
a white star.

So the line carries a plate of its own size with the drop shadow on that plate — the device the
banner, the entity chips and the door all use on this screen, for the reason each of them states:
an opaque fill is the only honest way to hold AA over 7,500 moving stars. The worst composite the
0.97 plate can produce is over a pure white star, `0.97*#0C1322 + 0.03*#FFF` = rgb(19,26,41), which
computes 9.51:1 for the ink and 7.19:1 for the gold. Measured on ten rendered frames: **9.49:1** and
**7.18:1**, worst pixel rgb(20,26,41) — the same number every frame, which is what "bounded by the
alpha rather than by the picture" looks like from outside. No contrast exemption is claimed for
this line: it is normal text meant to be read, and it is held to 4.5:1.

## Reproducing it

`app/ui/tests/home.js` carries both readings on every run:

- `THE TEMPORARY LINE: the picture is the same picture before it, under it and after it`
- `THE TEMPORARY LINE: its own plate holds the floor, measured on the rendered frame`

```
cd app/ui/tests && npm install && node home.js
```
