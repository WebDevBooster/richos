# RichOS renders from typefaces it ships — measured 2026-09-01

Machine: macOS 15.6, Apple M4. Everything below is a reading taken from a running
process, a compiled binary, or a rasterized glyph. Nothing is inferred from a
stylesheet.

`wiki/ceo-decisions.md` §22:

> For obvious reasons, there cannot be any reliance on any system fonts when
> implemented in the RichOS app later.

## The finding that reading the CSS would never have produced

The interface draws its own controls out of Unicode. The settings gear is a
literal `⚙` in `index.html`; the navigation toggle is `☰`; every close button is
`✕`; the voice control the CEO taps to stop talking is `◉`; the working state is
`◐`.

Measured against each face's own character map: of the **30 non-ASCII characters
the shipped UI renders**, Inter carries 23 and Newsreader carries 9, all nine of
them inside Inter's. Seven are in neither — `⋯ ▾ ◉ ◐ ☰ ⚙ ✕`. A browser that
cannot find a character in the named family does not fail; it walks silently to
the next one.

So removing the platform names would have left a system font drawing the gear,
the hamburger and every close button, in a stylesheet that looked perfect. Three
Noto subsets totalling **3,080 bytes** close it.

## 1. The red run — the defect, measured on the tree before the change

`scripts/render-check.js` pointed at `app/ui` as of `443d0c0` (`RICHOS_UI_DIR`):
**39 failures**, in `raw/red-before.txt`. Every one of the 30 characters
rasterized IDENTICALLY to the browser's default, and every one of the five
control probes reported its computed family as the old platform stack.

One check had to be rewritten because the red run exposed it as worthless:

* **`document.fonts.check('16px Inter', '⚙')` is not a discriminator.** Per the
  CSS Font Loading spec it answers true for a family installed on the machine as
  well as one loaded as a web font, so on the pre-change tree it returned true
  for all 30 characters and reported a clean pass over a UI drawing every one of
  them from a system font. Replaced with a **raster comparison**, which cannot be
  true for the wrong reason.
* **"differs from the browser default" is not a discriminator either.** The old
  stack also differed from the default — it named a system face rather than
  falling to the generic one. Replaced with a **shipped-vs-starved** comparison.

Both corrections were forced by the red run. Neither would have been found by a
green one.

## 2. The green run — same check, this branch

`raw/green-after.txt`, **0 failures**:

| | |
|---|---|
| faces loaded, not merely declared | Inter 1, Newsreader 1, RichOS Symbols 3 |
| characters drawn by a vendored face | 30 of 30 |
| controls drawn by a vendored face | 5 of 5 (`#rail-settings`, `#rail-toggle`, `#inspector-close`, `.voice-footnote-glyph`, `body`) |
| with every `.woff2` aborted | 0 faces load, and all 30 characters rasterize differently |

WebKit, not Chromium — Tauri renders through WKWebView on macOS, and the same
pinned Playwright version `app/ui/tests` uses.

**One green-run failure was the check being wrong, not the app.** An early green
run reported "no loaded face" for the monospace family. A `font-display: block`
face is fetched lazily and nothing in the initial DOM was set in it, so a present,
correct, embedded face reported as absent. The check now asks for each family by
name before judging it — and the red run still fails all three families, which is
what proves that fix did not turn the check into a formality.

**AND ONE GREEN RUN CAUGHT A REAL DEFECT I HAD JUST WRITTEN.** Rewriting the type
tokens for the approved faces, a paragraph of new prose landed AFTER the comment
above it had already closed, so `:root` carried a stray `*/` and WebKit dropped
declarations from that point. `--font` silently became nothing and every probe
reported its computed family as `-webkit-standard` — the browser's own default,
which is to say a system font, which is the exact defect this branch exists to
remove. It was invisible in the diff, and `contrast.js` and `appearance.js` had
already passed 32/32 and 19/19 over the broken file, because neither of them
measures type. Only the functional font check saw it. Both suites were re-run
after the fix; `scripts/css-comments.py` is the two-line check that would have
caught it at the write.

## 3. The binary really carries them

`strings` against the compiled `richos-tauri`, all 11 assets **PRESENT** as
`/fonts/...` keys: 6 `.woff2`, `fonts.css`, 4 `LICENSE-*.txt`. They are not in
`Contents/Resources`; `tauri-codegen` brotli-compresses everything under the
staged frontend into the executable itself.

## 4. The real launch, both ways

Not a screenshot of the screen — the app's window photographed **by its own
CGWindowID**, because it restores off-screen and dragging it onto the CEO's
display to look at it is not something a verification run gets to do to him.

* `raw/real-app-window-shipped.png` — built from this branch.
* `raw/real-app-window-starved.png` — the **same source**, rebuilt with
  `app/ui/fonts` taken out of the staged frontend, so the comparison is
  real-app-against-real-app rather than app-against-theory.

They differ throughout: line wrapping in the company picker, the sidebar
disclosure marks, the entity glyph, the gear. `raw/compare-sidebar.png` and
`raw/compare-footer.png` are the magnified side-by-sides.

`raw/real-app-boot.log` is the boot log. It is **byte-identical** to the starved
build's, which is the direct answer to whether vendoring introduces a boot line
for the new GUI boot check to account for: **it does not.**

### Residue: 0

Every launch in this record was killed by a trap that fires on every exit path,
and the count was asserted rather than assumed. `pgrep -f richos-tauri` reported
**0** before the first launch and **0** after every one of the three.

## 5. What CHANGED on screen, which is the part a design reviewer owns

The app stopped borrowing Apple's glyph artwork, so some controls are drawn
differently now. This is a consequence of complying with the ruling, not a
defect, and it is nobody's call but the design gatekeeper's. `raw/glyph-ink.txt`
has all 30 measured; the ones that moved most:

| | was (system) | now (vendored) | |
|---|---|---|---|
| `▾` U+25BE disclosure caret | 39x20 | 20x20 | **51% of the width** |
| `✕` U+2715 close button | 46x46 | 32x31 | 67% of the height |
| `◉` U+25C9 voice control | 58x58 | 41x41 | 71% |
| `⚙` U+2699 settings gear | 38x40 | 56x56 | 140% |
| `○` `●` U+25CB/CF | 29x29 | 50x49 | 169% |
| `→` U+2192 | 60x24 | 49x42 | 175% |
| `⊘` U+2298 unbound marker | 38x38 | 88x89 | **234%** |

The gear reads better; the disclosure caret reads smaller. Both are visible in
`raw/compare-sidebar.png`. **Raised for Urban rather than silently corrected** —
resizing a glyph in CSS to match Apple's proportions would be an infrastructure
change making a design decision, and `round-11.1` is choosing type for this
surface anyway.

## 6. Suites

| | |
|---|---|
| `cargo test -p richos-core` | **638 passed, 0 failed**, 2 ignored |
| `cargo test --bin richos-tauri` | **40 passed, 0 failed** |
| `app/ui/tests` (19 suites) | see below |

The UI suites **do** run here, contrary to the "18 of 19 cannot run" premise:
`lib/harness.js` documents `RICHOS_PLAYWRIGHT` as the opt-out for a missing local
install, and a matching playwright 1.61.1 plus a cached webkit-2311 are on this
machine.

**`contrast.js` went red and it was mine.** `9.settings` measured 72 nodes
against a floor of 74. Diagnosed by diffing the walker's own measured-node paths
between the two trees rather than by theory: `considered` is 132 per theme before
and after, `invisible` is 77 before and after, and exactly one path moves out of
measured — `span.nav-thread-title` — into `obscured`, its recorded example going
from "Partner book review" to "Q4 hiring". Inter's metrics are not the platform
face's, so the rail's rows sit at slightly different heights and one more thread
title falls under the assertiveness popover.

Nothing stopped rendering, which is the failure that floor exists to catch
(mutation 9b in `contrast.js` is `.nav-thread-title { display: none }`), and
check 11 still passes — every obscured node is measured on another surface, so
no coverage was lost, only relocated. The floor is updated to 72 with that
reasoning recorded in `contrast-debt.json` itself.

**`affordances.js` and `corrections.js` are red for a reason that is not mine**
and were red before this branch: both fail on the string "No loro corpus is
configured", a registry row against a Rust source this change does not touch.

**`techy.js` failed once under the full run and passes in isolation** — a 30s
click timeout waiting for `.nav-thread[data-thread-id="hiring"]`, under
concurrent load. Recorded as flake rather than dismissed as one.

## 7. What was NOT run, said plainly

The GUI boot check landed on main at `789a0fb`, after this branch was cut, and is
therefore not in this tree — which is why it is named in prose here rather than
cited as a path a reader of this branch could open. Its seven self-verification cases (S1, A0–A5) pass on this tree. Its boot
cases (B1–B7) **cannot** run here: they need main's `gui_boot_machine` example
and main's `main.rs`, which grew 223 lines in the same land. Running it against
this branch's older `main.rs` would test a different binary and report a verdict
about the wrong thing.

**It should be run after the merge.** The specific question it would ask of this
change — does vendoring add a boot line — is answered directly in §4: the boot
logs with and without the fonts are byte-identical.

## Reproducing

```
cd docs/verification/vendored-fonts-2026-09-01/scripts
RICHOS_PLAYWRIGHT=<path to a playwright install> node render-check.js
RICHOS_PLAYWRIGHT=... RICHOS_UI_DIR=<a checkout of app/ui at 443d0c0> node render-check.js   # red
bash real-launch.sh
bash real-launch-starved.sh
python glyph-ink.py ../raw/render-check.json
```
