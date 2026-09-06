# The bar that fills over the fastest case and then holds

**Echo (Rust and Tauri desktop engineer), 2026-09-06.**
**Branch:** `echo-opus-pb1`, cut from `5ce89b3`. **Builds on:** `echo-opus-cb1`'s compaction row
(`docs/verification/compaction-notice-2026-09-06/`), landed the same day.

The CEO asked whether the compaction row could show a bar like the splash screen's. He was told
a bar would have to fabricate progress, because a compaction's duration is unknown. **He
rejected that and specified the design himself:**

> *"It doesn't need to know. It just needs to move to almost full with the expected minimum time
> and then stay at 'almost full' until all finished etc."*

He is right, and the reason is worth writing down because it is the whole honesty of the thing:
**the bar never claims a completion it does not have.** It climbs over the shortest compaction
ever measured and then it STOPS. Reaching almost-full and holding is itself a true signal — *this
one is taking longer than the fastest case* — where a bar that stalls mid-way looks broken and a
bar that completes early lies.

---

## 1. The one number, re-derived rather than quoted

The brief handed me the population. I ran it again, over every `compact_boundary` frame in every
committed cell, because a number in a brief carries the command that produced it or it carries
the word unverified:

```
$ cd /Users/alex/ab/richos-wt/echo-opus-pb1
$ python3 -c 'import json,glob,statistics; ds=[json.loads(l)["compact_metadata"]["duration_ms"]
    for p in sorted(glob.glob("docs/verification/inner-doctrine-opens-2026-09-06/raw/*.jsonl"))
          +["docs/verification/compaction-notice-2026-09-06/raw/cellT1.jsonl"]
    for l in open(p) if l.strip() and json.loads(l).get("subtype")=="compact_boundary"];
    print(len(ds), min(ds), max(ds), statistics.mean(ds))'
16 38138 62029 49865.0

  2  inner-doctrine-opens-2026-09-06/raw/cellC0-control-no-doctrine.jsonl
  2  inner-doctrine-opens-2026-09-06/raw/cellC1-doctrine-system-prompt.jsonl
  3  inner-doctrine-opens-2026-09-06/raw/cellC2-doctrine-priming-turn.jsonl
  2  inner-doctrine-opens-2026-09-06/raw/cellC3-system-prompt-token-never-spoken.jsonl
  2  inner-doctrine-opens-2026-09-06/raw/cellC5-six-facts-system-prompt.jsonl
  3  inner-doctrine-opens-2026-09-06/raw/cellC6-six-facts-priming-turn.jsonl
  2  compaction-notice-2026-09-06/raw/cellT1.jsonl

  sorted: 38138 38397 39085 42950 43611 44813 46975 49790
          50158 50411 50654 58298 59901 60747 61883 62029
```

**Minimum and maximum stand exactly.** One correction, small and worth making so the next author
does not inherit it: the brief and `compaction-notice-2026-09-06/README.md` both carry
**"mean ~51,149 ms"** beside the 16-boundary population. That is the **n=14** mean (51149.4,
`echo-opus-q14`'s cells alone). Adding `cellT1`'s own 43611 and 38138 brings the n=16 mean to
**49865.0**. Nothing downstream reads the mean — this bar is paced on the minimum — and both
figures are now stated at the constant.

### Why the minimum and not the mean

Paced on the mean (49865 ms), **8 of these 16 would already be holding and 8 would still be
climbing** when they ended, so half of all compactions would show the bar jump forward at the end
from wherever it happened to have got to. Paced on the **minimum** it is climbing for the first
38.1 s of every compaction ever measured and holding for the rest of every one of them: one rule,
the same every time, and the hold means exactly what it says. The suite prints that 8/8 split on
every run.

### The number lives in one place

`machinery.rs`:

```rust
pub const COMPACTION_MEASURED_MIN_MS: u64 = 38_138;
pub fn measured_min_ms(kind: MachineryKind) -> Option<u64>
```

Nothing else types it. `timeline.rs` projects it onto the item as `measuredMinMs` from the KIND
alone, the webview reads it off the wire, and `app/ui/tests/compaction-progress.js` re-runs the
derivation above against the committed frames on **every run** and fails if the constant and the
record disagree. A tool call gets `None`: the committed population in
`native-claude-tool-status-2026-08-31/` runs from milliseconds to minutes, and a bar over that
would be invention rather than measurement.

---

## 2. What was built

| file | what |
|---|---|
| `app/crates/richos-core/src/machinery.rs` | the constant, its derivation, and `measured_min_ms(kind)` |
| `app/crates/richos-core/src/timeline.rs` | `Activity.measured_min_ms` -> `measuredMinMs` on the wire, + 2 tests |
| `app/ui/main.js` | THE PACED BAR — `notePacedActivity`, `pacePosition`, `paceLandingMs`, `renderWaitPace` |
| `app/ui/style.css` | `.wait-pace` / `.wait-pace-fill`, and the contrast arithmetic beside them |
| `app/ui/tests/compaction-progress.js` | ten checks, new file |

**`main.js` still does not know what a compaction is.** An activity row that carries a
`measuredMinMs` gets a bar; one that does not, does not. That was `echo-opus-cb1`'s rule for the
sentence and it survives intact — the suite proves it by driving an ordinary "Read a file" row
and asserting no bar appears.

**No change to `native.rs`, `reprime.rs` or `doctrine.rs`** (`echo-opus-dr1`'s this round), and
none was needed: these frames already reach `machinery.rs` as `ChunkMsg::Frame`.

### The three inputs, all observed

* **where it started** — the row's own `startedAt`, which is the LEDGER's instant for the frame
  that announced the pause. `merge_into` keeps the opening record's `at`, so a heartbeat 30
  seconds in still reports the instant the pause began and the bar cannot restart itself twice a
  minute.
* **how fast** — `measuredMinMs`, used as a rate and never shown.
* **when it ended** — the row's own `completed`/`failed` state, off the wire. Never a timer.

### Where the bar is

The curve is the splash bar's, verbatim (`splash.js` `BAR_SURGE = 0.12`): mostly linear with one
gentle surge early that fades out, and deliberately **not** an ease-out, because the classic
"stuck at 95%" feeling IS an ease-out. Monotonic on [0,1], exactly 0 and 1 at the ends — verified
over 100001 samples, no step backwards, max eased exactly 1.000000.

```
     0 ms ->  0.00%      10000 ms -> 32.24%      38138 ms -> 92.00%   <- the floor; it stops here
  1000 ms ->  4.18%      19069 ms -> 46.00%      45000 ms -> 92.00%
  5000 ms -> 19.10%      30000 ms -> 70.08%      62029 ms -> 92.00%   <- the longest ever measured
```

**0.92 is a judgment, not a measurement, and here is the arithmetic behind it.** The band is
capped at 680px and pads 28px a side; the bar sits in the text columns, so it is 604px wide
(WebKit measured 602px in the run below, the difference being the grid's own rounding). 8% of
that is **48.3px of empty track** — a gap the eye reads as "not finished" across the room, where
0.95 would leave 30px and start to read as a rounding error.

---

## 3. The case he did not name, and it is the one that decides whether this is honest

A compaction that finishes **faster** than the shortest ever measured. The bar is then somewhere
short of almost-full and the ending is a fact. Snapping from a third to full is the jump that
makes a person distrust every bar they meet afterwards.

**What I chose: the paint catches up at a FIXED SPEED — one bar-length per 700 ms — floored at
180 ms and never longer than the wait it is drawing.**

```
  1 ms    from  0.0%  ->  180ms   the `too_few_groups` attempt (capped by the wait itself)
  8000 ms from 27.7%  ->  506ms
  20000ms from 47.4%  ->  368ms
  43611ms from 92.0%  ->  180ms   cellT1 turn 3 — the ordinary landing
```

**Why a fixed speed rather than a fixed duration.** How far the bar had to come is then legible
in how long the sweep takes; with a fixed duration a bar at 20% and a bar at 92% travel at wildly
different rates and the motion says nothing. The speed is 59x the climbing rate (one bar-length
per ~41 s), which is the point: it does not pretend to be work. The work is already over and this
is the paint arriving after it.

**Why the floor.** 180 ms is the settle transition's own duration, inside §17.4's allowed
150–220 ms band (`main.js`, the turn-settle block). Below it a movement stops being read as a
movement and becomes a jump; the ordinary landing from 92% would otherwise be 56 ms.

**Why the cap at the wait itself.** `cellT1` holds two compactions abandoned **1 ms** after they
began (`too_few_groups` — what a 2% threshold override does to a conversation with nothing to
summarize). A 644 ms gold sweep over a 1 ms event would make a non-wait look like a wait. Capped,
it gets the 180 ms floor: a flick, which is what happened.

---

## 4. A dead turn does not leave a bar looking alive

`echo-opus-cb1` fixed the truth for the SENTENCE: past `QUIET_AFTER_MS` (35 s) with no heartbeat
the band stops describing what it last saw and names the silence, because at that point the app
genuinely does not know whether the compaction is still running. **The bar obeys that one rather
than a second one of its own** — it is drawn only while the band is DESCRIBING the row it paces.
Three ways it goes:

| what happens | the bar |
|---|---|
| another signal takes over the sentence (*"Writing the reply"*) | gone, same instant |
| the band goes quiet — a child that died mid-compaction | gone, same instant, width back to 0 |
| a terminal `rich://turn-status` | the whole band is gone |

Also dropped on `stopping`: the CEO asked for the turn to end, and whatever the child is still
doing inside it, pacing it toward a finish is not what he is waiting to see.

From the suite, driven at cellT1's own cadence with the heartbeat withheld:

```
   20s   47.44%  Making room to keep going · 20s ago   [working]
   40s  (no bar)  Nothing new for 40s                  [quiet]
  2m40s  (no bar)  Nothing new for 2m 40s              [quiet]
  failed  (the whole band is gone)
```

Nothing is remembered off-screen: the width is asserted back to `0`, so a heartbeat arriving late
redraws the bar at its TRUE position (a pure function of elapsed) rather than resuming where it
was abandoned.

---

## 5. No number, anywhere

The bar is `aria-hidden="true"` and carries **no `role="progressbar"`**. A progressbar owes an
`aria-valuenow`, and every value it could carry would be a proportion of a span that is not this
wait's. The sentence above it is what a screen reader gets, and it is the same sentence a sighted
CEO reads. Measured attributes, from the run:

```
class=wait-pace data-contrast-role=indicator aria-hidden=true
text: ""   detail: "Making room to keep going · 20s ago"
```

The suite asserts the absence of `role`, `aria-valuenow`, `aria-valuemin`, `aria-valuemax`,
`aria-valuetext`, `aria-label` and `title`, and that no percentage reached the band. Two Rust
tests assert the summary contains no digit in any of the three phases.

---

## 6. Contrast — three boundaries, each held by the thing that carries it

Computed with `tests/lib/contrast.js` (the same arithmetic `tests/contrast.js` runs) and then
**re-measured off the rendered DOM in WebKit, in both themes**, with the painted `data-theme`
asserted first so a light run cannot silently be a second dark one. Both elements also carry
`data-contrast-role="indicator"`, so the SHIPPING gate walks them too.

| what it carries | element | dark | light | floor |
|---|---|---|---|---|
| the bar's full extent | `.wait-pace` border vs the paper | **4.57:1** | **3.35:1** | 3:1 |
| how far along it is | `.wait-pace-fill` vs the track | **6.29:1** | **4.87:1** | 3:1 |
| the moving thing itself | `.wait-pace-fill` vs the paper | **7.68:1** | **5.48:1** | 3:1 |

```
dark   paper #0c1322   track interior #24262a   border #6b7ea8   fill #c2a35c
light  paper #eae6dd   track interior #e1d9c9   border #767c8d   fill #715715
```

**Nothing here is exempt, and the one faint thing is declared where a reviewer meets it.** The
track's INTERIOR is `--gold-soft`, which measures 1.22:1 dark and 1.13:1 light against the paper.
It is not an exemption, because it is not an indicator: it is the unfilled ground the fill is read
AGAINST, and the boundary a reader actually needs — where the gold stops — is the 6.29 / 4.87 row.
The bar's EXTENT is carried by the border at 3:1, which is why the border exists at all. The suite
prints the interior's ratio on every run rather than leaving it to be discovered.

This is the same call `splash-library.js` already recorded, when it lifted entry #2's strap edge
from 2.52:1 to 4.89:1: *"the strap's edge is what marks the bar's full extent — a non-text
indicator with a 3:1 floor."*

**Why the three cannot be one element.** A chain of two 3:1 steps needs **9:1 end to end**, and
signal gold is 7.68:1 on the dark paper — so with a gold fill and a luminance-separated track,
*some* boundary is always under 3:1. Working the algebra on the dark ground (`--paper` L=0.0079,
`--live-mark` L=0.3947): a track 3:1 from the ground needs L >= 0.1157, and a track 3:1 below the
gold needs L <= 0.0982. There is no such value. A **third** value — the border, `--line-control`,
the token that exists because *"the border of a form control is a non-text indicator and owes
3:1"* — is what makes all three payable at once. The alternative was an ink-white bar (`--ink` is
14.55:1 / 14.90:1, the only fill that clears 9:1 in both themes), and the CEO named the splash
bar, which is gold.

**Watched to fail.** With light `--line-control` temporarily set to `#cfc9bb` the light check went
red — `light .wait-pace border vs the paper = 1.33:1, floor 3:1` — and `style.css` was restored
from git immediately. The full mutation table is §8.

---

## 7. Every check, and the command that produced it

```
$ cd app && cargo test -p richos-core
   892 direct passed, 0 failed, 3 ignored, + 5 doc-tests
   (890 direct before this branch; 2 tests added, both in timeline.rs)

$ cd app/ui/tests && node compaction-progress.js
   10 PASS, 0 FAIL

$ node compaction-notice.js        # echo-opus-cb1's, unchanged by me
   6 PASS, 0 FAIL

$ node waiting-state.js
   10 PASS, 0 FAIL

$ node affordances.js
   0 FAIL   (3 before the WAIT_TICK_MS commit — see section 9)

$ node docs-claims.js
   6 PASS, 0 FAIL
   (it failed twice first: app/README.md's crate total 893 -> 895, and a table row for
    the new suite in app/ui/tests/README.md)

$ node run.js                      # the full sweep
   29 discovered, 29 ran, 0 skipped, 562 checks observed against 456 declared
```

`node compaction-progress.js`, verbatim:

```
== the paced bar — WebKit ==
  PASS  the span the bar is paced on is re-derived from the committed frames, not typed
          n=16  min=38138  max=62029  mean=49865.0 ms
          COMPACTION_MEASURED_MIN_MS = 38138  (wire field: measuredMinMs)
          paced on the mean, 8 of 16 would already be holding and 8 still climbing
  PASS  it climbs over the measured floor and then HOLDS, short of full
            5000 ms   19.10%     19.1%  Making room to keep going · 5s ago
           19069 ms   46.00%       46%  (half the floor)
           30000 ms   70.08%   70.075%  (the wire's 30.000s heartbeat)
           38138 ms   92.00%       92%  (the shortest compaction ever measured)
           45000 ms   92.00%       92%  (past every fast case)
           60000 ms   92.00%       92%  (the second heartbeat)
           62029 ms   92.00%       92%  (the LONGEST boundary ever measured)
          held still for 23891 ms at 92.00%, painted 553.8px of a 602px track
  PASS  only a frame off the wire fills it, and it lands in 180ms from almost-full
          held at 92.00% -> 100.00% on `compact_result`, 180ms, painted 602.0/602px
  PASS  a compaction that finishes faster than the floor catches up rather than snapping
            8000 ms   27.75%  climbing
            ending    100.00%  catch-up 506ms
            1 ms      100.00%  catch-up 180ms  (the abandoned attempt)
  PASS  a child that dies mid-compaction takes the bar with the description
  PASS  the bar publishes no number, no value and no progressbar role
  PASS  a row with no measured floor gets no bar, and a new sentence takes the bar away
  PASS  under reduced motion the bar still advances and animates nothing
          10s 32.24% -> 20s 47.44%, transition "none"
  PASS  WCAG AA on the paced bar, computed — dark
  PASS  WCAG AA on the paced bar, computed — light
```

**Twenty consecutive runs**, counted rather than eyeballed, on the branch head:

```
run 1..20:  exit=0 pass=10 fail=0     (every one)
TOTAL: 20 green, 0 not green, out of 20
```

**Frames** in `frames/`, written by the suite itself under `RICHOS_PACE_FRAMES`:
`held-at-almost-dark.png` (holding at 92%, 1m 2s into the turn), `landed-dark.png`,
`caught-up-dark.png`, `dead-turn-dark.png` (quiet, no bar), `bar-dark.png`, `bar-light.png`.

---

## 8. Proven able to fail — every check, one mutation each

Each mutation was applied to the PRODUCT, the suite run, and the file restored with
`git checkout --` in the same step. The tree was verified clean (`git status --short` empty)
before the sweep.

| # | mutation | reds |
|---|---|---|
| 1 | `COMPACTION_MEASURED_MIN_MS` 38_138 -> 40_000 | check 1 — *"machinery.rs ships 40000 ms but the shortest compaction in the committed record is 38138 ms"* |
| 2 | `PACE_ALMOST` 0.92 -> 1.0 | check 2 — *"almost-full is 1, which is neither almost nor full"* |
| 2d | `if (u >= 1) return 1;` — complete on time passing | checks 2 and 3 — *"the bar reached FULL on time passing alone, at 100.00%"* |
| 2e | both clamps removed at once | checks 2 and 3 — *"...at 106.76%"* |
| 2f | the hold creeps instead of holding still | checks 2 and 3 — *"the bar went past almost-full without an ending: 93.72%"* |
| 3/4 | `paceLandingMs` returns 0 (a snap) | checks 3 and 4 — *"the catch-up is 0ms where a fixed speed over 72.25% gives 506ms"* |
| 4b | the catch-up ignores how far it has to come | check 4 — *"the catch-up is 180ms where a fixed speed over 72.25% gives 506ms"* |
| 5 | the quiet state keeps its bar | check 5 — *"a bar sitting at 92.00% over a dead child is the spinner this band exists to remove"* |
| 6 | `role="progressbar" aria-valuenow="50"` added | check 6 — *"the bar carries role=progressbar..."* |
| 7 | an unpaced row defaults to 38138 | check 7 — *"an unpaced row got a bar, which means the bar was paced on something invented"* |
| 8 | the reduced-motion branch removed | check 8 — *"reduced motion got a transition: width 1000ms linear"* |
| 9 | light `--line-control` -> `#cfc9bb` | check 9 (light) — *"1.33:1, floor 3:1"* |

**Two mutations did NOT redden, and that is a finding rather than a hole.** Removing the clamp on
`u`, and separately removing the clamp on `eased`, each left every check green — because the two
clamps are **mutually redundant**: with either one present the position cannot pass `PACE_ALMOST`.
Removing both at once (2e) reddens immediately, and so does bypassing both (2d). The redundancy is
defense in depth and is left in place; it is recorded here so the next author does not read a
single clamp as load-bearing and "simplify" both away in one pass.

---

## 9. What the full sweep found, and what a reader should NOT commit

**It found a real defect of mine, through a checker that is not about timing at all.**
`affordances.js` reads every string literal in `app/ui/` as a candidate CEO-facing state, and
`"width 1000ms linear"` is not recognized as a CSS value — `looksLikeCssValue` strips the `1000ms`
and is left with `width`, which is not in its CSS keyword vocabulary. Three checks went red,
including its own positive control:

```
FAIL  every derived state is classified, and every classification is a real state
        NEW USER-VISIBLE STATE, NOT CLASSIFIED
        actual ["width 1000ms linear   <- main.js:2180"]
```

The cheap fix would have been a row in `lib/state-registry.js`, or a new word in a keyword list
whose own header calls itself *"a language, not an inventory"*. **Neither is the fix, because the
checker was pointing at something real:** that `1000` was written TWICE — once as the band's
`setInterval` and once inside the transition string — and the two MUST be equal or the
interpolation is wrong. Each repaint asks the bar to travel to the position it will hold when the
next repaint arrives, so a transition shorter than the tick stops early and one longer never gets
there. It is `WAIT_TICK_MS` now, used in both places, and the transition is built from it exactly
as the landing already builds its own duration (`12de8df`). `affordances.js` is 0 FAIL; the only
`width` literals left in the whole of `app/ui/` are `index.html`'s two real labels.

**And the churn.** `node run.js` in this worktree rewrites roughly **100** committed
`app/ui/tests/shots-*/*.png` for reasons unrelated to any change on this branch — `echo-opus-cb1`
reproduced it twice on the same day and recorded it
(`compaction-notice-2026-09-06/README.md` §6). It happened again here: **99 files**. Every one was
restored with `git checkout --` before committing, so **this branch carries no screenshot churn**.
The only images it adds are the six under `frames/` in this directory, which this suite wrote
itself. It is worth someone's attention as its own row; it is not this one.

---

## 10. Open, and named rather than quietly absorbed

1. **A reload that joins a live compaction gets no bar until the next heartbeat (up to 30 s).**
   `resetWaitBandForThread` re-establishes the band from `rich://turn-status` alone; the pace
   comes from an activity upsert, and a snapshot's activity rows are not replayed into the band.
   This is the SAME degrade the sentence already has — `lastWhat` is null on a late join too, so
   the band reads *"Nothing new for Xs"* until a signal arrives — and the bar and the sentence
   therefore appear together. Named rather than built: seeding the pace from the reloaded model
   is a change to the band's join-late contract, not to the bar.
2. **`compaction-notice.js` now drives a payload one field short of the crate's.** Its
   `emitCompaction` predates `measuredMinMs`, so no bar appears in its runs or its committed
   frames. Its six checks are unaffected and all still true; its "after" frames now show slightly
   less than the product does. That file is `echo-opus-cb1`'s and my brief permits only additive
   changes to it, so it was not touched.
3. **The band's one-second timer is not stopped on `visibilitychange`.** `startOrStopWaitTimer`
   carries the `document.hidden` guard, but the listener at `main.js:1274` calls the TIMELINE's
   `startOrStopTimer` and not the band's, so nothing invokes it when the window is hidden.
   Pre-existing, not this change's, and harmless to the bar either way: the fill is a pure
   function of two timestamps, so a hidden window recomputes rather than accumulates. Worth a row.
4. **Two compactions inside one turn would share one row, and therefore one bar.** Inherited
   unchanged from `compaction-notice-2026-09-06/` §7.1 — the wire gives the spans no correlation
   id. Never observed: 16 of 16 measured boundaries are one per turn.
5. **`PACE_ALMOST = 0.92` is a judgment.** The pixel arithmetic behind it is in §2 and in
   `main.js`, and the suite holds the PROPERTY (0.85 < almost < 0.97, and it never reaches full on
   time alone) rather than the value, so moving it is a one-line decision and not a test rewrite.
6. **`app/README.md`'s crate-total line conflicts with main.** Main moved to `a49b92e` while this
   branch was in flight and now reads `936 tests + 5 doc-tests; 932 direct, 4 child-only`; this
   branch carries `895 / 892 direct, 3 child-only`, a +2 delta on its own base. **The resolution
   is main's number PLUS 2 — `938 tests + 5 doc-tests; 934 direct, 4 child-only` — and
   `node docs-claims.js` after the merge is the arbiter, never a typed number.** It is the ONLY
   file this branch and main both touch:

   ```
   $ git diff --name-only 5ce89b3 a49b92e | sort > main.txt     # 60 files
   $ git diff --name-only 5ce89b3 HEAD    | sort > mine.txt     #  7 files
   $ comm -12 main.txt mine.txt
   app/README.md
   ```

   Acknowledged at `.claude/inflight-acks/a49b92e1d182.echo-opus-pb1.ack`.

---

**No audio device was opened.** Everything ran in headless WebKit with no voice mode; the RichOS
app was never launched. The CEO was asleep and that was a standing order.
