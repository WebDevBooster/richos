# The two splash screens — what was run, what it showed, and what could not be shown

Everything here was produced against `app/src-tauri/target/release/bundle/macos/RichOS.app`
built from this branch by `app/scripts/package-app.sh` (ad-hoc signed, cdhash
`dda44e6fae2068b8ef66603c5f579d37790863d9`), and against the shipped renderer under WebKit —
the engine Tauri renders through on macOS.

## 1. The CEO's rule, from the real app

> *"USE THE APPROVED SPLASH SCREEN #1 to always deterministically show as SPLASH SCREEN #1
> and splash screen #2 to always show as splash screen for the SECOND APP START in RichOS
> v1. From the third app start onwards: Only splash screen #1."*

Four real launches, `cwd=/`, a launchd-shaped environment (`HOME`, `USER`, `LOGNAME`,
`SHELL`, `TMPDIR`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and nothing else), each quit cleanly
by Apple Event before the next. The launch ledger was moved aside first and restored after,
so this ran against a fresh-install state and left the CEO's own record exactly as it found
it. `scripts/real-boot.sh`; logs in `raw/boot-1.log` … `raw/boot-4.log`.

| start | the shell said | the ledger's ring says was SHOWN |
|---|---|---|
| 1 | `[richos] launch: fresh (start 1, 1 window(s))` | `round-11/v1` — **#1** |
| 2 | `[richos] launch: fresh (start 2, 1 window(s))` | `round-11/v2` — **#2** |
| 3 | `[richos] launch: fresh (start 3, 1 window(s))` | `round-11/v1` — **#1** |
| 4 | `[richos] launch: fresh (start 4, 1 window(s))` | `round-11/v1` — **#1** |

The ring is the strong half. `main.js` pushes onto it only when `RichSplash.state.shown` is
true, so each row is a record of a screen that was actually drawn, written by the app itself
during a real launch — not a claim about what it would have drawn.

Every boot log is otherwise identical and clean: nine `[richos]` lines each, all of them
resolutions or declared gaps, ending in `boot complete — every line above is what this
launch resolved`.

**Residue: 0.** Thirteen application launches across four scripts this session; every script
counts before and after and every one reported `0`. `pgrep -f richos-tauri` at the end of the
work: `0`.

## 2. WHAT COULD NOT BE PHOTOGRAPHED ON THIS MACHINE, and how it was measured instead

**The three-second animation could not be filmed from the real window.** Stated plainly
because it is a gap in the evidence, not a detail.

`screencapture -x -R <rect>` on the display fails outright here —
`could not create image from display` — and `screencapture -x -l <CGWindowID>`, which reads a
window's own backing store and is what earlier verification work in this repository used,
returns the SAME BYTES every time. One launch was filmed at 4 Hz for nine seconds:
**36 frames, 1 distinct** (`scripts/real-film.sh`). An earlier pass at 1 Hz over twenty
seconds produced runs of byte-identical files. This window server is not compositing an
unfocused window on this session, so the backing store holds whichever frame it last
composited.

Two real frames survive and are kept here because they are honest evidence of what they are:

* `raw/real-app-first-composited-frame.png` — the first frame the real app composited: the
  splash curtain's ground, lamp and vignette, before the plinth has risen. It is proof the
  splash is the app's FIRST paint rather than something that arrives after it.
* `raw/real-app-window-plinth.png` — a later stale frame from the same launch, holding the
  plinth, the mark, the wordmark, the rule and the tagline at 18px.

Neither shows the bar mid-run, and no frame from this machine does.

**So the moving evidence is the acceptance suite**, which drives `index.html`, `splash.css`,
`splash-library.js`, `splash.js`, `style.css` and `main.js` from disk under WebKit —
the same engine, the same files, the same renderer. `tests/splash.js` check 22 samples the
bar's width every 60ms for the whole life of the curtain and asserts it is monotonic, that it
is at zero before it starts, and that it is FULL at exactly the 3000ms hold; check 12b times
three real launches end to end; check 23 photographs the composited frame in both color
schemes and computes the AA ratios off the pixels.

## 3. It runs once

> *"The animation is only supposed to happen ONCE. NO LOOPING."*

Three legs, because no one of them is enough — see `mutation-runs.txt`, where the first
version of the second leg let a real loop through and was fixed rather than trusted.

1. **Structural.** `splash.js` has no `setInterval`, no replay path, and no `focus`,
   `visibilitychange`, `pageshow` or `blur` listener; `requestAnimationFrame` appears in
   exactly two places, one to start the single pass and one inside it. Read off the source
   with comments stripped, so the prose describing the rule cannot satisfy the check.
2. **Observed.** The bar's width, every 60ms for 3.9s — through the landing and for the
   ~950ms the curtain has left after it. Monotonic, zero before 600ms, full at 3000ms, still
   full at the end.
3. **Reported.** `RichSplash.state.barPasses` is 1 and `state.barStopped` is true. This leg
   exists because leg 2 cannot see a loop whose period is longer than the second the curtain
   has left — and a deliberate restart injected at 3950ms went through leg 2 undetected.

The approved mockups carry `HOLD_AFTER` and `AUTO_REPLAY` so a viewer can judge the run more
than once. `AUTO_REPLAY` is `false` in both, and nothing of the sort exists in the app.

## 4. The durations, measured

| what | measured |
|---|---|
| the default | curtain cleared at **3201ms**, reason `held` |
| a screen carrying `seconds: "5"` | cleared at **5190ms**, reason `held` |
| a screen carrying `seconds: "12"` | clamped to 5 and cleared at **5196ms** |
| his first keystroke against a 3000ms hold | **258ms** — the hold never catches his hand |
| the app never reporting ready | gone by 4.4s on its own ceiling |

`SPLASH_SECONDS = 3` and `MAX_SPLASH_SECONDS = 5` are named in `splash.js` and asserted by
number. The ceiling is `holdMs + 1000`, so it is still 4000 at the default and no longer
cuts a five-second screen off at four.

## 5. Contrast, on the composited frame, in both color schemes

Measured from a screenshot at 1440x900, `deviceScaleFactor: 2`, mid-load — not from computed
styles, because the lamp (`soft-light`), the vignette and the grain all sit ABOVE the plinth
and a DOM checker cannot see through them. `contrast-debt.json` already carries the tagline
as a named `knownUnresolvable` for that reason; this check answers what that one cannot.
Glyph and thread colors are the median of the brightest 5% of pixels in the box; backgrounds
are the modal value of a bare strip. Numbers are re-measured on every run and printed by
check 23 — the run at the head of this branch reported:

| | foreground | background | ratio | floor |
|---|---|---|---|---|
| #1 | tagline, 18px | plinth surface | **6.77:1** | 4.5 |
| #1 | the rule | plinth surface | **7.12:1** | 3 |
| #1 | wordmark ink | plinth surface | **12.98:1** | 3 |
| #1 | the bar's fill | the ground below it | **7.54:1** | 3 |
| #1 | the bar's fill | its own unfilled track | **5.37:1** | 3 |
| #2 | tagline, 18px | plinth suede | **6.56:1** | 4.5 |
| #2 | the rule | plinth suede | **6.41:1** | 3 |
| #2 | wordmark ink | plinth suede | **11.75:1** | 3 |
| #2 | the gold thread | the ground below the strap | **9.62:1** | 3 |
| #2 | the gold thread | the strap leather it lies in | **8.53:1** | 3 |
| #2 | the strap's edge | the ground above it | **3.91:1** | 3 |

**BOTH THEMES.** §15 carries one permanent exception — *"because of its nature the start
screen will always need to be in dark mode"* — and `splash.js` clamps it with
`RichTheme.forceDark(true)`. Rather than measure one and assume, check 23 photographs BOTH
color schemes, asserts every ratio in each, and asserts that every element which holds still
is pixel-identical across them. That proves the clamp rather than assuming it. The bar's fill
is excluded from the pixel comparison and only from that: the two photographs are two
separate launches and the fill is MOVING, so comparing it pixel-for-pixel measures scheduler
jitter. Its floors are asserted in both themes instead, which is the stronger claim.

### One declared item, with the arithmetic

**Neither bar's UNFILLED track is asserted against the ground.** It is unfilled material, not
the state. The boundary that conveys progress is the fill against the track and against the
ground, and both are asserted above with margin.

For **#1** the two cannot both be satisfied inside this palette. The track is the ruled
signal at 22% — the rule before it is struck, which is the CEO's own direction for what that
bar is. Clearing 3:1 against the ground needs a track luminance >= 0.118; clearing 3:1
against the gold fill needs <= 0.095. No value is both. So the boundary that carries the
state is the one made to pass, at 5.37:1, and the track stays the ghost of the rule.

For **#2** the empty needle holes measure about 1.3:1 against the leather — they are punched
leather, drawn as texture, and the run of them reads as a dotted line by its rhythm rather
than by its contrast. The strap's own EDGE marks the bar's full extent and IS asserted, at
3.91:1; its value was lifted from `rgba(58,74,108,.6)` (2.52:1) to `#56698E` for exactly that
reason.

**Nothing is exempted for being skippable.** The tagline is the only text on either screen,
it is at 18px, and it clears 4.5:1 in both.

## 6. What is in this directory

| | |
|---|---|
| `mutation-runs.txt` | the nine runs that prove the rewritten suite can fail, including the one that passed first time and forced a fix |
| `raw/boot-1.log` … `boot-4.log` | the real shell's own boot log, four launches, from `cwd=/` |
| `raw/real-app-first-composited-frame.png` | the splash is the app's first paint |
| `raw/real-app-window-plinth.png` | the plinth, mark, rule and 18px tagline in the real window |
| `scripts/real-boot.sh` | four real launches with the ledger moved aside and restored |
| `scripts/real-launch2.sh` | the same through `open`, photographing by CGWindowID |
| `scripts/real-film.sh` | the 4 Hz film that showed the backing store does not update here |
| `scripts/window-id.py` | CGWindowID lookup by pid |
| `scripts/gen-strap.js` | generates #2's two SVG tiles from the mockup's own `mk(41)` |
