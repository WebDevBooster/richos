# The settings button and the two composer buttons — before and after, measured

**CEO, 2026-09-19**, on the nightly he watched at 8pm the evening before. His screenshot —
`ceo-2026-09-18-composer-and-settings-button.png`, three arrows — is kept with the briefs in the
**private `richos-hq` repository** and is deliberately not published here, so a reader of this
repository has this record and not that image.

> So, if those things haven't been fixed since, then the settings button needs to be properly
> centered vertically and the right padding for that button needs to be reduced to 15px. And the 2
> buttons at the bottom need to be either vertically center aligned relative to the text input or
> have the same height as the text input because otherwise it looks weird.

They had not been fixed since. This record is the eight frames and the numbers under them.

## How these frames were taken

Headless WebKit (Playwright 1.61, the engine Tauri ships on macOS), through `app/ui`'s own
acceptance harness — `lib/harness.js`'s `leaveHome` + `bootSettled`, the real `index.html`, the real
`style.css`, the shipped `mock.js` fixture. **No app was put on screen**: another agent's on-screen
measurement was running on this Mac, and only one on-screen agent is allowed at a time.

The **before** arm is not an approximation. `richos/app/ui/style.css` was replaced on disk with
`git show f918f185:richos/app/ui/style.css`, the frames were taken, and the file was restored and
verified byte-identical with `git status`. So a `before-*.png` is `f918f185`'s own bytes rendered by
the same engine as the `after-*.png` beside it.

Each arm: 1024x700 (the app's own minimum, and the size it restores itself to) and 1400x950, in dark
and in light. `before-measurements.json` and `after-measurements.json` carry the geometry read out of
the same page in the same instant as each frame.

The lighting is **stated**, with the harness's own `SEED_THEME`, and each frame re-reads
`data-theme` after boot and refuses to be saved under a name it is not painting. CEO §63 made the
shipped default preference `system`, so a frame that said nothing would follow whatever this
machine's browser context happened to be — which is exactly how a record changes palette without
anyone deciding.

## The three numbers

| | before (`f918f185`) | after | the CEO asked for |
|---|---|---|---|
| settings button center vs `#stage-header`'s | **+12px** (button 38, header 26) | **0px** (both 26) | properly centered vertically |
| settings button right padding | **18px** | **15px** | 15px |
| `#talk-toggle` / `#send` height vs `#input-shell`'s | **-6px** (40 against 46) | **0px** (46 against 46) | same height as the text input **or** centered on it |
| `#talk-toggle` / `#send` center vs `#input-shell`'s | **+3px** (664 against 661) | **0px** (both 661) | (as above) |

Identical at both window sizes and in both themes, before and after — all eight frames agree to the
pixel, which is what the two JSON files are for.

The settings button did not merely sit low: its box ended at y=58 against a header whose bottom
border is at y=52, so six pixels of it hung through the line. That is the overhang his first arrow
points at, and it is why "properly centered" is a measurement here (`(52 - 40) / 2 = 6`) rather than
an opinion.

## Which of his two options the composer took

**The same height as the text input.** The field grows with what he types (`#input`'s
`max-height: 112px`) and `align-items: flex-end` is what keeps the two controls beside the LAST line
of a long message rather than beside its middle — so centering is right in one state and floats them
mid-box in the rest, while matching the height is right at one line and degrades to bottom-flush.
Measured at a grown 112px field: both controls sit 0px from its bottom edge.

The height is derived rather than typed — `--control-h: calc(var(--field-h) + 2px)`, where
`--field-h` is `#input`'s own height declaration and the 2px is `#input-shell`'s border — so the Text
size row moves the field and the buttons together instead of opening a 4px gap.

## What holds it

`app/ui/tests/chrome-align.js`, 13 checks, run on this machine:

```
pre-fix stylesheet (f918f185's own bytes):   11 FAIL, 2 PASS
this branch:                                 13 PASS
```

The two that pass on both are the negative control (which asserts the DEFECT, and would mean the
other eleven prove nothing if it ever came back clean) and "the buttons stay flush with a grown
field", which was already true and is recorded as such rather than claimed as a fix.

## Privacy gate

All 8 frames OCR-scanned before commit for an email address, the operator's account name and his
username:

```
/opt/homebrew/bin/tesseract <frame>.png stdout 2>/dev/null \
  | grep -inE '@[a-z0-9.-]+\.[a-z]{2,}|<account name>|<username>|/Users/<username>'
```

**0 hits over 8 frames.** Nothing was redacted, because there was nothing to redact: these are
`mock.js`'s own fixture companies (Northwind Traders, Lumen Labs, Harbor Analytics, Meridian Group,
Tidewater Films, Kestrel Supply) with `user_name: null`, in a headless browser with no access to the
operator's machine state. The frames carry no name, no path and no address.

## Why no committed `shots-*` PNG was regenerated on this branch

The settings button is on **every** screen, so a full `node run.js` rewrites about **125** of the
committed reference PNGs under `app/ui/tests/shots-*/`. None of them is a failure — a changed shot
prints a `shot changed:` notice and the suite still exits 0 — and all 53 suites are green on this
branch with the committed shots in place.

**They are not all this branch's doing, and that was measured rather than assumed.** With ONLY the
pre-fix stylesheet restored on an otherwise identical tree, a full pass was taken and compared
against the committed bytes:

```
125 committed shots differ after a full pass on this branch
 39 of those 125 ALSO differ with the pre-fix stylesheet restored — drift that predates this work
 86 differ only because the chrome moved
```

The 39 are `shots-5b` (12), `shots-26` (5), `shots-updates` (4), `shots-splash` (4), `shots-home` (3),
`shots-contrast` (6), `shots-5c`/`shots-5d` (4) and `shots-10-1/10-1-start-screen-always-dark.png`.
Some of that is the run-to-run drift this directory's own README already tabulates (`shots-home/*`,
`shots-splash/*`, the start screen); the corrections desk is not in that table and is the largest —
`shots-5b/5b-02-two-asks-waiting.png` differs by **4.63%** of its pixels with the pre-fix stylesheet
in place, in a 718x637 box that is the desk panel itself, and it is **byte-identical across two
consecutive runs**, so it is a stale reference rather than a flake.

So committing the regenerated set would have carried three other branches' drift in under this one's
name, at the same time as two other in-flight branches (`theme1`, and the §62 splash work) are
rewriting shots of their own. **A whole-directory shot refresh is one deliberate pass on main after
the in-flight shot-touching branches land, and this branch is not it.** What is on record instead is
this directory: eight frames whose numbers are the CEO's three, and the count above for whoever runs
that pass.

## Not in scope, found while measuring

`main.js`'s `autoGrow()` writes the field's height inline from `scrollHeight`, and none of the eleven
places that call it is a text-scale change — so between using the Text size row and the next
keystroke the field keeps a height computed at the previous scale while everything around it
rescales. Measured at 110%: field 46px (inline 44px from the previous scale) beside buttons at
48.39px, correcting itself to 48px on the next keystroke. Before this work the same window showed a
6px gap the other way, so the magnitude improves either way. The fix is one `autoGrow()` call on a
`RichTheme` change; `main.js` was held by another agent this session and is untouched here.
