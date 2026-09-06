# URBAN SIGNOFF — P6, the assignment panel, third review

**Date:** 2026-09-06
**Reviewer:** Urban, Principal Product Designer
**Branch:** `urban-opus-p6`, cut from `codex/durable-orchestration`
**Worktree:** `/Users/alex/ab/richos-wt/urban-opus-p6`
**Reviewed at:** `e276ba3b845e66fc7e313e46a637b381241ab7a6` — the branch tip, read from `git rev-parse`.
Nothing of mine is under review; the tree was clean before this audit and clean after it.
**Supersedes:** `URBAN_SIGNOFF_2026-09-06_00.29.md` (P5, 7/10, withheld, at `b45145f`) and
`URBAN_SIGNOFF_2026-09-05_21.40.md` (P4, 4/10, withheld, at `63e93ac`).

> **Why this file is not at `ui-ux-signoffs/` in the repository root.** The permanent nine-entry
> root ruling. Both predecessors put it here and both were right to. This audit adds no root entry.

## VERDICT

**Score: 9 / 10. SIGNOFF GRANTED.** The bar is ≥9 plus documented gaps. This clears it.

**Both things it was withheld for are fixed, and fixed at the root rather than moved.** I looked
hard for the third displacement, because that is what the last two reviews were: the same defect
relocated. I did not find it on the decision. **The question now has no height cap at any size in
either theme, it never clips, its answers always follow it in one flow, and every hidden state
carries a visible, reachable cue** — 50 measured openings, both themes, five sizes, every one
backed by a positive-content control so that no "nothing is clipped" of mine is green over a
surface that failed to render. The machine contract is gone from history, and I proved that by
compiling the real Rust projection and rendering its output in the shipping shell, not by reading
a JavaScript fixture. Contrast is clean in both themes with zero exemptions and zero text below
16px. Ten of the eleven claimed gaps hold on inspection.

**I did find the defect class surviving somewhere the revision did not go, and it is why this is
9 and not 10.** "Show me what happened" — the one door the panel offers into what Rich actually
did — did not get the reading controls the decision and the picker got. On the ordinary path it
hides 45.5% of itself at 520×680 with zero cues; on an imported plan it hides 68.9% at
**1400×900**, and an actionable control sits under that cut and fails a hit test at rest. That is
a real gap and it is ranked first below. It is not a blocker, because it costs him part of an
account of past work rather than the basis of a decision, and because the fix is the function the
author already wrote three lines away.

**One gate got weaker in this commit and nobody would have noticed.** `data-contrast-role="indicator"`
on `.run-status` downgrades the shared walk's floor for that element's **text** from 4.5:1 to
3:1 — so the panel's most important line, "1 needs you", is no longer held to the text floor. I
proved it with a matched control in both themes. Nothing fails today; the check that would catch
it tomorrow does not.

---

## VERIFICATION MODE

| | |
|---|---|
| Surface | The real shell: `app/ui/index.html` + `main.js` + `mock.js` + `style.css` + `runs.js` + `timeline.js`, loaded from disk over `file://` |
| Engine | WebKit via Playwright 1.61.1 (`/Users/alex/ab/deeply/node_modules/playwright`) — the engine Tauri ships in on macOS and the one every suite in `app/ui/tests/` targets |
| Mode | Headless WebKit, real compositor, real computed styles, real hit tests, real wheel and keyboard input, screenshots out of that compositor |
| Windows | One page at a time. No two-user comparison — not applicable; this is a single-operator desktop surface |
| Viewports | 1400×900, 1280×800, 1024×768, 760×720, 520×680 |
| Themes | Both, every state, every measurement |
| Context | A real opened conversation, reached through the home screen and the rail by the steps a person takes; the panel measured where it lives, in `#composer-zone` above the composer |
| Bridge | Run commands are scripted — `mock.js` returns `null` for `get_run` and throws on the rest, so a browser preview cannot execute a durable controller. Everything else in the shell is the shipped code |
| Backend text | **Not scripted.** `cargo run -p richos-core --example run_view_probe` was compiled and executed, and its three serialized views were rendered in the shell and read off the screen |
| Fixtures | The author's `lib/assignments.js` (which now carries the long question and the eightfold variant), plus mine: a twenty-assignment portfolio, a six-receipt autonomous assignment, and an eight-step imported plan with a failing step |
| Harness | `/private/tmp/claude-501/-Users-alex-ab-femcboost/9befc211-b0af-4e74-b96a-8fcafc7d45ba/scratchpad/p6/` — `geom.js`, `negctl.js`, `negctl2.js`, `sweep.js`, `contrast.js`, `indicator-gate.js`, `borders.js`, `interact.js`, `history.js`, `history-cue.js`, `history-controls.js`, `history-real.js`, `reach.js`, `vocab.js`; screenshots in `shots/` |

**The contrast arithmetic is not mine.** I loaded `app/ui/tests/lib/contrast.js`'s own `pageScript()`
into the page and used its exported math and its hit-test background resolution, so every ratio
below is the number this project's own gate produces.

**Every number in this document was read off that live surface.** Anything I could not verify is
in "What I did not check", by name and with the reason.

---

## THE PROBES CAN FAIL — I MADE THEM, BEFORE I TRUSTED A SINGLE GREEN

Five failure modes on the geometry probe, each reverted immediately:

| # | Mutation | Result |
|---|---|---|
| 1 | Remove `[data-run-pause]` from the DOM | `present:false, ok:false` — an absent node never reports a pass |
| 2 | `#managed-run{position:relative;top:900px}` | `ok:false, belowFold:782, offscreen:5` |
| 3 | Opaque `div#urban-veil` over the viewport, geometry unchanged | `ok:false, blockers:["div#urban-veil"]` |
| 4 | Shrink `[data-run-end]` to zero size | `ok:false, zero:true` |
| 5 | Re-impose `max-height:15vh` on `.run-question-body` | `questionClipped:63, maxH:115.2px` — reverted: `0`, `none` |

**And the specific trap the coordinator named — an absence assertion passing over a surface that
never rendered.** "The question is not clipped" is green against a blank panel. So every open
measurement carries a positive-content control (`question.scrollHeight>0` AND `answerCount>0` AND
the reading panel has non-zero height AND the panel has text). Proven able to fail three ways:

| Case | The absence assertion says | The control says |
|---|---|---|
| Reading body emptied | `clipped=null` — reads as a pass | **NOTHING RENDERED — measurement void** |
| `.run-reading` removed | `clipped=null` — reads as a pass | **NOTHING RENDERED — measurement void** |
| `#managed-run` hidden | `clipped=0`, `strip=0` — reads as a pass | **NOTHING RENDERED — measurement void** |

**50 of 50 open/picker measurements passed the positive-content control.** No green below is green
over a surface that did not render.

**The contrast walk is not blind to this panel either.** Re-running the identical 20 walks with the
library's `NORMAL`, `LARGE` and `INDICATOR` floors substituted to 21:1 (substitution asserted to
have applied, 3/3 sites) produced **672 failures reporting their real ratios**. Silence there would
have meant the walk never reached the panel.

**The branch's own gate is load-bearing.** I mutated the shipped app/ui/runs.js (on the unmerged branch `codex/durable-orchestration`; written without backticks because it does not exist on `main` yet), deleting only the
`data-run-more` marker while leaving the button rendering, and ran `node app/ui/tests/runs.js`:
**three checks went red** — "Long decisions keep question and answers in one uncapped flow with
persistent reading controls", "The long-question guard rejects both the old cap and a missing
reading cue", and "Duplicate titles use dates before internal references and portfolios have
explicit reading cues". Reverted; tree clean.

---

## 1. THE QUESTION AND ITS ANSWERS — MEASURED AT ALL FIVE SIZES, BOTH THEMES

The P5 blocker was `max-height: 20vh` tightening to `15vh`, hiding 53% of a realistic question at
520×680 with the answers directly beneath the cut. **That cap is gone.** `.run-question-body` is
`white-space: pre-wrap` and nothing else; `getComputedStyle(...).maxHeight` reads **`none`** in all
50 openings. The decision now lives in a separate reading surface above the compact strip, opened
by an explicitly named **Review decision** control.

Identical in dark and light at every size — the two themes produced byte-identical geometry, so one
table serves both and I state that rather than printing it twice.

### The compact strip at rest (never opened)

| State | 1400×900 | 1280×800 | 1024×768 | 760×720 | 520×680 |
|---|---|---|---|---|---|
| running | 164px / **18.2%** | 164px / 20.5% | 164px / 21.4% | 164px / 22.8% | 164px / **24.1%** |
| decision pending | 198px / **22.0%** | 198px / 24.8% | 198px / 25.8% | 198px / 27.5% | 198px / **29.1%** |
| twenty assignments | 164px / 18.2% | 164px / 20.5% | 164px / 21.4% | 164px / 22.8% | 164px / 24.1% |
| empty | 123px / 13.7% | 123px / 15.4% | 123px / 16.0% | 123px / 17.1% | 123px / 18.1% |
| load failure | 163px / 18.1% | 163px / 20.4% | 183px / 23.8% | 163px / 22.6% | 183px / 26.9% |

**Resting share across all 60 measurements: 11.4% minimum, 29.1% maximum.** The response's claim
"below 30% at all five reviewed sizes" is true. It is true by 0.9 percentage points at 520×680, so
one extra line of status text breaks it; the branch's own assertion (`size.height < height*.3`)
will catch that.

### The decision open — the author's fixture question (two lines)

| Window | Reading panel | Body visible / content | Hidden | Cue | Question cap | Question clips |
|---|---|---|---|---|---|---|
| 1400×900 | 164px, fits | 106 / 106 | **0px** | not needed | `none` | **0px** |
| 1280×800 | 164px, fits | 106 / 106 | **0px** | not needed | `none` | **0px** |
| 1024×768 | 184px, fits | 126 / 126 | **0px** | not needed | `none` | **0px** |
| 760×720 | 184px, fits | 126 / 126 | **0px** | not needed | `none` | **0px** |
| 520×680 | 184px, fits | 126 / 126 | **0px** | not needed | `none` | **0px** |

### The decision open — my predecessor's long question, three options

| Window | Reading panel | Body visible / content | Hidden | Cue visible and hit-testable | Question clips |
|---|---|---|---|---|---|
| 1400×900 | 284px / 31.6%, fits | 226 / 226 | **0px** | not needed | **0px** |
| 1280×800 | 284px / 35.5%, fits | 226 / 226 | **0px** | not needed | **0px** |
| 1024×768 | 324px / 42.2%, fits | 266 / 266 | **0px** | not needed | **0px** |
| 760×720 | 324px / 45.0%, fits | 266 / 266 | **0px** | not needed | **0px** |
| 520×680 | 398px / 58.5%, fits | 340 / 386 | 46px (11.9%) | **Read more below — yes** | **0px** |

### The decision open — eightfold question, twelve options (a deliberate stress)

| Window | Reading panel | Body visible / content | Hidden | Cue | Clicks to the end | Last answer after scrolling |
|---|---|---|---|---|---|---|
| 1400×900 | 540px / 60.0%, fits | 482 / 646 | 164px (25.4%) | **yes** | 1 | visible, hit-testable |
| 1280×800 | 480px / 60.0%, fits | 422 / 726 | 304px (41.9%) | **yes** | 1 | visible, hit-testable |
| 1024×768 | 460px / 59.9%, fits | 402 / 1005 | 603px (60.0%) | **yes** | 2 | visible, hit-testable |
| 760×720 | 432px / 60.0%, fits | 374 / 906 | 532px (58.7%) | **yes** | 2 | visible, hit-testable |
| 520×680 | 398px / 58.5%, fits | 340 / 1346 | 1006px (74.7%) | **yes** | 4 | visible, hit-testable |

**Across all 50 openings, in both themes:**

- **`questionClipped` = 0px everywhere.** The question itself never has hidden content.
- **`answersAfterQuestion` = true everywhere.** No answer is ever laid out above the question, so
  no answer can sit pinned beneath a cut question. The response's claim is accurate.
- **The reading panel fits the window everywhere** (`top >= 0` and `bottom <= innerHeight`, 0
  exceptions).
- **Every state with hidden content shows a reachable cue.** The only twelve rows with hidden
  content and no "Read more below" are the twelve where I had already scrolled to the end, and
  every one of those shows "Read previous" instead.
- **Pause and End are fully hit-testable in every one of those states**, including while a reading
  panel is open, and both stay enabled while a decision command is in flight.

**Verification basis: measured live on the target surface, five sizes, both themes, hit-tested,
with a probe proven able to fail five ways and a positive-content control proven able to fail three.**

### Is "Read more below" / "Read previous" pagination? No.

The rule is absolute, so I measured rather than asserted:

- **Step size 272px against a 340px viewport — 68px of overlap, 20%.** Nothing is skipped and
  nothing is snapped to a boundary.
- **The container is a genuine scroll region.** Mouse wheel moved it 0 → 200. `PageDown` moved it
  to 500. `ArrowDown` to 535. The buttons are supplementary, not the only way through.
- **No page numbers, no page count, no page boundaries, no "of N".** The vocabulary sweep below
  found zero pagination language in any rendered state.

This is a scroll affordance that survives macOS overlay scrollbars, which is exactly what P5 asked
for. **It is not pagination and it does not need to be defended as an exception.**

---

## 2. THE MACHINE CONTRACT — GONE, AND PROVEN THROUGH THE REAL RUST PROJECTION

P5's second blocker was that "Show me what happened" printed the whole registrar contract twice,
and that no JavaScript inventory could ever see it because the text is composed in Rust.

`src-tauri/src/run_view.rs` now projects the CEO's request as the task description and Rich's
accepted scope as the completion expectation. I did not take that on trust. I compiled
app/crates/richos-core/examples/run_view_probe.rs (on the unmerged branch `codex/durable-orchestration`; written without backticks because it does not exist on `main` yet) — which runs the **production**
`registration::validate` → `autonomy::plan` → `RunController::tick` → `projection::view` chain with
a scripted host and a real verification tick — and rendered its three serialized views in the
shipping shell, opening every nested disclosure a curious CEO would open. What is on the screen:

> **Draft the Q4 investor update. Do not send it or contact anyone. (Checks passed)**
> Completion checks: I'll deliver the complete draft with figures reconciled to Finance. It will remain private.
> Checked draft.md against the approved figures. Nothing was sent.

And on an amendment:

> **Use the approved figures only. (Checks passed)**
> Completion checks: I'll use the approved figures and retain all other requirements.
> Earlier instructions still apply unless changed: Draft the Q4 investor update. Do not send it or contact anyone. I'll deliver the complete draft with figures reconciled to Finance. It will remain private.
> Checked draft.md against the approved figures. Nothing was sent.

**Searched live, on the rendered text, for sixteen terms: `verbatim`, `acceptance constraint`,
`Preserve prohibitions`, `certify partial`, `Conversation context`, `Sensitive conversation`,
`CEO_DECISION`, `richos:review`, `Intended outcome`, `registrar`, `cycle budget`,
`contract revision`, `verification state`, argv, and filesystem paths. On both autonomous views:
NONE.** On the imported view, one hit — the workspace path, which P4 and P5 both accepted as
behind the disclosure and which I am not re-charging.

**This is the strongest thing in the revision.** A boundary test that compiles the actual Tauri
projection module into a core-crate example, and a suite check that renders its output and reads
the screen, is a real answer to "no inventory can see Rust-composed text". It also self-heals: if
the registrar's envelope wording changes, `human_contract`'s `strip_prefix` stops matching and the
probe's own `assert_eq!` fails rather than the panel quietly reverting to printing the contract.

**Verification basis: compiled and executed the Rust probe; rendered its output live in the real
shell; read the screen.**

---

## CONTRAST — COMPUTED, EVERY NODE, BOTH THEMES

20 walks: 10 states × 2 themes (empty, running, decision, long question, eightfold question,
load failure, history open, picker, twenty-row picker, scope editor). **1,224 nodes checked.
0 failures. 0 unresolvable. 0 exemptions claimed. 0 panel text nodes below 16px.**

The panel resolves to exactly two paint pairings, so the table is short and complete rather than
long and repetitive. Every ratio below is the shared library's own arithmetic.

### Text — floor 4.5:1 (nothing in the panel is large text: every node is 16px at weight 400/600/700)

| Node | Text | Size/W | Dark | Light | |
|---|---|---|---|---|---|
| `p.run-status` | "Working · task 2 of 3" | 16px/600 | **14.55:1** `#dfe4ee` on `#0c1322` | **14.90:1** `#0c1322` on `#eae6dd` | PASS |
| `p.run-status` | "No assignment yet" | 16px/600 | **14.55:1** | **14.90:1** | PASS |
| `p.run-status.run-attention` | "1 needs you" | 16px/700 | **14.55:1** | **14.90:1** | PASS |
| `p.run-status.run-attention` | "3 need you · Working · task 2 of 3" | 16px/700 | **14.55:1** | **14.90:1** | PASS |
| `p.run-status.run-attention` | "Rich couldn't update this assignment…" | 16px/700 | **14.55:1** | **14.90:1** | PASS |
| `p.run-question` | "Rich has used the allowance without finishing." | 16px/600 | **14.55:1** | **14.90:1** | PASS |
| `p.run-question` | "The Q4 numbers Finance signed off on show 18%…" | 16px/600 | **14.55:1** | **14.90:1** | PASS |
| `div.run-question-body > p` | "Keep going allows up to 10 more attempts…" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `div.run-question-body > p` | "This changes what the board is told…" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `form.run-editor > p` | "What should Rich do differently?…" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `details.run-history > summary` | "Show me what happened" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `details.run-history > summary` | "Import an assignment" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `div#managed-run > p` | "Tell Rich what needs doing in the conversation…" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `run-history-body > ol > li > p` | "Gather the figures (Checks passed)" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `run-history-body > p.run-checks` | "Completion checks: The figures match the ledger" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `div#managed-run > button` | "Review decision" / "Close decision" / "Refresh assignments" | 16px/400 | **13.02:1** `#dfe4ee` on `#141e34` | **17.02:1** `#0c1322` on `#f7f5ef` | PASS |
| `div.run-actions > button` | "Pause assignment" / "End assignment" / "Continue assignment" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `span.run-title` | the assignment title, plain and date-qualified | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `[data-run-picker] > span` | "1 assignment ▾" / "20 assignments ▾" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-reading-controls > button` | "Close" / "Read more below" / "Read previous" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-decision .run-actions > button` | "Keep going" / "Use approved approach N" / "Write an answer" / "Change instructions" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `form.run-editor > button` | "Go back" / "Confirm end" / "Confirm decision" / "Send decision" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-choices > button` | a picker row | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-choices > button.run-attention` | a picker row needing him | 16px/700 | **13.02:1** | **17.02:1** | PASS |
| `details > summary` (nested) | "Technical details" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `button:disabled` | any control during a mutation | 16px/400 | **6.08:1** | **6.22:1** | PASS |

### Non-text indicators — floor 3:1

| Indicator | Dark | Light | |
|---|---|---|---|
| `.run-reading` panel boundary, 1px `--line-control`, measured against what is actually painted behind it (the conversation `ARTICLE`) | **4.57:1** `rgb(107,126,168)` on `rgb(12,19,34)` | **3.35:1** `rgb(118,124,141)` on `rgb(234,230,221)` | PASS |
| `textarea` border, 1px `--line-control` | **4.57:1** | **3.35:1** | PASS |
| `.run-attention` 3px left border, `--ink` on `--paper` | **14.55:1** `rgb(223,228,238)` on `#0c1322` | **14.90:1** `rgb(12,19,34)` on `#eae6dd` | PASS |
| Keyboard focus ring, reached by a real Tab press so `:focus-visible` genuinely matched | `rgb(223,228,238)` | `rgb(12,19,34)` | PASS |

**The reading panel's drop shadow is `rgba(76,96,135,0.26)` / `rgba(60,70,95,0.24)` at 16px blur.**
It is decoration, not the boundary — the 1px border does the identification work and clears the
floor on its own. Recorded so nobody re-derives it.

**Two things stated so nobody has to re-derive them.**

1. **The shared walk does not check labeled buttons as indicators**, by its own declared and
   reasoned bound (`lib/contrast.js:531-556`): a button that says "Pause assignment" is identified
   by its word, and the word is already held to 4.5:1. I record this as the library's stated
   position, not a gap in this branch.
2. **No exemption is declared anywhere in the panel, so there is no claim of skippability to audit,
   and none is needed** — the whole panel is at or above 16px.

### The type floor — clean

Across all 20 walks, in both themes: **zero panel text nodes below 16px.** `contrast-debt.json`
gains floor entries and no new debt signatures.

---

## 3. THE GATE THAT GOT WEAKER — AND NOBODY WOULD HAVE SEEN IT

`runs.js` now sets `status.dataset.contrastRole = "indicator"` on `.run-status.run-attention`, and
the same on attention rows in the picker. The response presents this as declaring the attention
border for measurement, which is a good instinct. But `lib/contrast.js:385` reads:

```js
if (el.closest("[data-contrast-role='indicator']")) return INDICATOR;
```

That is `thresholdFor` — **the floor for TEXT.** Putting the marker on the paragraph that holds the
headline moves that headline from the 4.5:1 text floor to the 3:1 indicator floor.

**Proven live, in both themes, with a matched control:**

| Theme | Node | `data-contrast-role` | Ink forced to | Computed ratio | Shared gate |
|---|---|---|---|---|---|
| dark | `p.run-status.run-attention` — "1 needs you" | `indicator` | `#636363` on `#0c1322` | **3.09:1** | **GREEN** |
| dark | `p.run-status` — "Working · task 2 of 3" (control) | none | `#636363` on `#0c1322` | **3.09:1** | **CAUGHT** |
| light | `p.run-status.run-attention` — "1 needs you" | `indicator` | `#6c6c6c` on `#eae6dd` | **4.22:1** | **GREEN** |
| light | `p.run-status` — "Working · task 2 of 3" (control) | none | `#6c6c6c` on `#eae6dd` | **4.22:1** | **CAUGHT** |

**Nothing fails today.** The real values are 14.55:1 and 14.90:1. What has happened is that the
single line the whole panel is built to deliver — the one that tells him he is needed — has been
quietly removed from the floor that protects it, by a change whose stated purpose was to protect
something else. That is the failure class this review exists to catch, and it is why this is a
must-fix rather than a note.

**The fix is small: carry the border on a dedicated element (a `::before`, or a child span with no
text) and put `data-contrast-role="indicator"` on that, leaving the paragraph on the text floor.**
The same applies to `.run-choices button.run-attention`, which takes the marker from the same code
path — I did not prove that one with a matched control, because my chosen ink resolved against the
raised-surface background rather than the paper, so I state it as following by construction and not
as measured.

**Verification basis: mutated live in the real shell; ratios computed with the project's own
arithmetic; matched control in both themes.**

---

## 4. WHERE THE DEFECT CLASS SURVIVED

### 4.1 "Show me what happened" never got the reading controls

The revision gave the decision and the picker a persistent, overlay-scrollbar-proof cue. The
history overlay — `.run-history-body`, `max-height: 40vh`, `overflow: auto`,
`scrollbar-gutter: stable` — did not get it. `scrollbar-gutter` reserves nothing under WebKit's
overlay scrollbars; the measured gutter is the 2px border and nothing else.

**The ordinary path**, a single autonomous assignment registered from a conversation, with the
receipts a real controller accumulates (the plan permits 20 attempts):

| Receipts | 1400×900 | 1024×768 | 520×680 | Cues |
|---|---|---|---|---|
| 1 | 0px hidden | 0px | 35px (11.5%) | **0** |
| 3 | 0px | 36px (10.6%) | 225px (**45.5%**) | **0** |
| 6 | 20px (5.3%) | 207px (**40.4%**) | 510px (**65.4%**) | **0** |

`shots/history-real-520-light.png` shows the consequence: the last visible line sliced through the
middle of its glyphs — "Nothing was sent." cut in half — with no cue, no toolbar and no gutter.
That is the same screenshot P5 filed as the blocker, taken of a different element.

**And an imported plan puts a control under that cut.** Eight steps, one `needs_attention`:

| Window | Hidden | Cues | "Retry after reviewing the result" |
|---|---|---|---|
| 1400×900 | 792px (**68.9%**) | **0** | clipped by the panel, **fails the hit test at rest** |
| 520×680 | 1060px (**79.7%**) | **0** | clipped by the panel, **fails the hit test at rest** |

Twelve wheel notches inside the overlay reach it and it becomes hit-testable, so it is
**undiscoverable, not unreachable** — and that distinction is the whole reason this is a ranked
gap and not a withheld signoff. But P4 was failed for a control off-screen with no cue at rest, and
this is that, in the same panel, in the commit that fixed it everywhere else.

**The branch's own gate does not look at it.** `tests/runs.js` asserts reading cues on
`.run-question-body` and `.run-choices`, and nothing on `.run-history-body`.

**Verification basis: measured live at five sizes in both themes, with hit tests, on three fixture
shapes; wheel-scroll reachability confirmed by real input.**

### 4.2 "Read previous" does not survive being spoken

`ceo-decisions.md` §25: an option must mean the same read or heard. "Read more below" does.
**"Read previous" does not, and it is worst exactly where it is used most.** Over a list of twenty
assignments, spoken aloud, "read previous" means the previous *assignment*, not the previous part
of the list. It is also not the pair of "Read more below" — the pair is "Read more above", or
"Back to the top".

### 4.3 Two Close controls, one of them ambiguous

With the decision open, the screen shows **"Close"** in the reading toolbar and **"Close decision"**
in the strip, at the same time, doing the same thing under different names. And "Close decision",
spoken, reads as *settling* the decision — next to a "Confirm decision" button, that is a real
ambiguity about whether pressing it commits something. It does not; nothing is lost. But he has to
find that out by pressing it.

---

## 5. THE ELEVEN CLAIMED GAPS

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1, 6 | Hidden question and oversized strip | **RESOLVED** | `max-height: none` on the question in all 50 openings; 0px clipped everywhere; strip 11.4–29.1% at rest; reading panel fits the window in every case; cue present in every state with hidden content |
| 2 | Machine contract in history | **RESOLVED** | Compiled `run_view_probe`, rendered its three real projections live, searched the screen for sixteen machine terms — none on either autonomous view |
| 3 | False classifications | **RESOLVED** | The two `NOT-RENDERED` delimiter entries are deleted. The nine new ones are Echo's home/splash diagnostics; I spot-checked two (`state.fieldError`, `home.js:1234`, written and never read into the DOM; `home.js:803`'s reject text) and both are honest. **I did not audit all nine** |
| 4 | Incomplete source inventory | **RESOLVED, and the reuse is faithful** | `lib/ui-sources.js` is byte-identical to Echo's at `58ee862` except for one added `ROLES` row declaring `runs.js` — nothing narrowed, nothing removed. It derives 19 files from `index.html` plus the runtime closure and reconciles against disk in both directions. **My own mutations:** an unclassified sentence in `updates.js` now fails by name at `updates.js:47` (this is P5's mutation 4, the one that passed at `b45145f`); an unwired file under `app/ui/` fails by name. The `if (name === "runs.js")` special case is generalized to every derived source, as P5 asked. The stale `affordances.js` comment is gone |
| 5 | Grammar | **RESOLVED** | "1 needs you" alone when a decision is selected; "3 need you · Working · task 2 of 3" at three; read off the screen in both themes |
| 7 | Internal references | **RESOLVED** | Twenty rows with identical titles disambiguated by creation date only; "private-id" / `run-0000` style references absent from the picker, headline and confirmations |
| 8 | Imported argv | **RESOLVED** | Behind a nested "Technical details" disclosure, rendered as `check-report report.txt` — a quoted command line, not a JSON array |
| 9 | Empty state | **RESOLVED** | "Tell Rich what needs doing in the conversation. He will carry out the assignment and check the result." is visible immediately; the disclosure reads "Import an assignment". It reads authored |
| 10 | Missing screenshots | **RESOLVED** | Seven `assignment-*.png` committed in `shots-contrast/`. **They reproduce byte-for-byte** — a full contrast run left all seven untouched while nineteen older surfaces drifted |
| 11 | Long picker | **RESOLVED** | Twenty rows, decisions sorted to positions 1–3, 69.6% hidden at 520×680 with the cue visible and hit-testable, "Read previous" present at the end |
| — | Attention indicator declared | **RESOLVED IN SUBSTANCE, REGRESSED AS A GATE** | The border is measured (14.55:1 / 14.90:1). The declaration also downgrades the element's **text** floor to 3:1 — §3 above |

**Ten resolved. One resolved with a gate regression. And one defect of the same class the review
was about, in a surface the response does not mention: the history overlay.**

---

## 6. VOCABULARY, DIALECT, PAGINATION — SWEPT ON THE RENDERED TEXT

Twelve distinct rendered texts across four states × two themes × two widths, including the decision
open, the scope editor, the end confirmation, the picker and the history open. Searched for machine
vocabulary, raw error prefixes, filesystem paths, pagination language, slash options and non-en-US
spellings.

**One hit, and it is deliberate:** `Error: Corrupt committed journal`, inside the opened history in
the load-failure state. P5 accepted that placement — the friendly sentence comes first and the raw
string sits behind the disclosure — and I am not re-charging it. I note only that it is still a
developer console line containing a word he does not have, under a summary that says "Show me what
happened".

**Zero pagination language. Zero non-American spellings. Zero slash-built options. Zero absolute
labels in the panel's own copy.**

---

## 7. THE SUITES

Run on this branch, from a clean tree, with the tracked screenshots restored afterwards.

| Suite | Result |
|---|---|
| `node app/ui/tests/runs.js` | **23 / 23 PASS**, including the compiled Rust projection check |
| `node app/ui/tests/affordances.js` | PASS — "the affordance rule holds" |
| `node app/ui/tests/contrast.js` | PASS — 52 walks across 26 surfaces, 0 debt hits, 0 new, 0 worsened, 0 exemptions |
| `node app/ui/tests/docs-claims.js` | PASS — 6 / 6 |

**Tree discipline:** `git status --short` was empty before this audit and is empty after it. The
contrast suite overwrote 19 tracked screenshots (pre-existing nondeterminism on older surfaces, not
this branch's doing); all 19 were restored with `git checkout --`. Three deliberate mutations
(`updates.js`, an unwired file, `runs.js`) were reverted immediately and the tree verified clean
after each.

---

## DOCUMENTED GAPS, RANKED

**Must fix before the next land — neither blocks the CEO seeing the ordinary path:**

1. **Give `.run-history-body` the reading controls the decision and the picker got.** The
   `readingPanel()` function is already in the file. Today the history hides 45.5% of itself at
   520×680 on the ordinary path with three receipts, 68.9% at 1400×900 on an imported plan, with
   zero cues at every size in both themes — and in the imported case the "Retry after reviewing the
   result" control is under the cut and fails a hit test at rest. Add the same assertion to
   `tests/runs.js` that already guards the question, pointed at a fixture with enough receipts to
   fail it.
2. **Move `data-contrast-role="indicator"` off the text-bearing elements.** Put it on a dedicated
   border-only child so `.run-status.run-attention` and `.run-choices button.run-attention` stay on
   the 4.5:1 text floor. Proven above with a matched control in both themes.

**Should fix:**

3. **"Read previous" → "Read more above"** (or "Back to the top"). §25: it does not mean the same
   thing heard as read, and over a list of assignments it means something else entirely.
4. **One Close, one name.** "Close" in the toolbar and "Close decision" in the strip are visible at
   once and do the same thing; "Close decision" reads as settling the decision next to "Confirm
   decision".
5. **"Completion checks:" now labels Rich's first-person promise** — "Completion checks: I'll
   deliver the complete draft with figures reconciled to Finance." The content is right and the
   label is wrong for it. "What Rich agreed to deliver" is the same information without the
   mismatch. Grant's call, not mine, but it should not ship as it reads.
6. **The amendment line runs two voices together.** "Earlier instructions still apply unless
   changed: <the CEO's instruction> <Rich's reply>" is joined by a newline that HTML collapses,
   so his own words and Rich's promise become one run-on sentence in the most confusing moment in
   the flow. Two lines, or two labels.
7. **Receipts render in a monospace `<pre>`.** Now that the projection strips the machine prefix and
   what is left is Rich's own prose, the terminal font makes his sentence look like log output. It
   is the one place the CEO reads what actually happened; it should be set in the body face.
8. **The reading toolbar sits above the content**, so "Read more below" is as far as it can be from
   the edge where the text is cut. A cue at the boundary — a fade plus the control — is where the
   eye already is.
9. **`human_contract`'s fallback is the raw contract.** If the envelope ever fails to match, the
   projection renders the machine text. The failure direction for a display projection should be a
   neutral line, not the bytes. The probe catches a format change today because it composes both
   sides from the same source; a durable journal written by an older format would not be caught.
10. **A one-task assignment renders as a numbered list of one**, and its single item repeats the
    title verbatim from the picker directly above. Every conversation-registered assignment has
    exactly one task, so this is the ordinary shape, not an edge case.
11. **The 30% strip budget has 0.9 points of headroom at 520×680.** One more line of status text
    breaks it. The branch's own assertion will catch it; worth knowing it is that close.

---

## THE ONE DIRECTION

**Finish the job on the third surface.**

P5's direction was "make the question the thing that cannot be cut." That has been done, properly,
and I checked it at every size in both themes with a probe I first made fail five ways. The panel
now has one shape and it is the right one: a compact status line, a chooser, a named door to the
decision, the controls that stop the work, and one door to the account.

**Everything behind those doors should behave the same way, and one of them does not.** The
decision reads with a persistent cue; the picker reads with a persistent cue; "Show me what
happened" still cuts its content silently and hides a control while doing it. The fix is to use the
function that is already in the file, on the element that did not get it, and to point the gate at
a fixture long enough to fail. Gaps 1, 7, 8 and 10 all fall out of treating the history as a
reading surface rather than a box.

Gap 2 is a separate, smaller job and it is not optional: a check that reports green over a real
failure is the thing this panel has been rejected twice for, and this commit introduced one.

---

## WHAT I DID NOT CHECK, AND WHY

- **The panel inside the shipped Tauri binary.** Reviewed in WebKit via Playwright, the engine Tauri
  ships in on macOS and the one every suite here targets. I did not build or run the desktop app.
  **Window chrome, real WKWebView scrollbar behavior and the OS accent color are unverified** — and
  the scrollbar one matters for gap 1, because with the operator's "Show scroll bars" set to
  "Always" the history overlay has a cue and with the macOS default it does not. **I measured the
  default.**
- **The Rust suite beyond the projection probe.** I compiled and ran `run_view_probe` because its
  output is display text and display text is mine. I did not run `cargo test -p richos-core`, the
  controller mutations, or the desktop harness. **Those numbers are unverified by me** — they are
  Tom's and Ray's, and a design gate that spends an hour recompiling is not doing its job.
- **Seven of the nine new `NOT-RENDERED` classifications.** I spot-checked two and both were honest.
  The nine belong to Echo's home and splash surfaces, not this panel. **The other seven are
  unverified by me.**
- **Whether the controller honors what the panel sends.** I verified the panel issues
  `respond_run_decision` with full assignment, task and question identity and the exact typed text.
  Whether the controller then rejects a stale question or is idempotent on replay is a claim in the
  response document that **I did not test and am not endorsing.**
- **The spoken presentation.** I read the copy and judged it as spoken. I did not hear it.
- **Portfolios beyond twenty, generated option lists beyond twelve, and live provider behavior.**
  Named as open by the author; I agree they are open.
- **`.run-choices button.run-attention`'s contrast-floor downgrade.** It takes the marker from the
  same code path as the status line, so it follows by construction, but my matched control resolved
  against the wrong background and **I did not prove that one.**

---

## MERGE NOTE — THE COLLISION HAS COLLAPSED

Recorded because the lead asked.

P5 predicted a substantive collision with `echo-opus-gt2` over the derived source manifest. **It is
gone.** This branch carries Echo's `lib/ui-sources.js` from `58ee862` **byte-identical except for a
single added line** — `"runs.js": { role: "ui", why: "the durable assignment panel and its decision
controls" }` — which Echo's own reconciliation *requires*, since it fails by name on any shipped
file it cannot classify. Nothing was narrowed and nothing was removed; the derivation is still a
derivation. The typed `UI_SOURCES` array is gone, and the `runs.js` special case in
`state-strings.js:inventory()` has been generalized to every derived source, which is exactly what
P5 said should happen.

**Note for whoever lands both:** `94eff69` and `58ee862` are on `echo-opus-gt1`/`gt2` and are **not
on `main`**. `lib/state-registry.js`, `tests/contrast.js`'s `SURFACES`, `tests/affordances.js`'s
fixture lists and `contrast-debt.json`'s floors are still additive on both sides, and the node-count
floors will need re-baselining **by running the suite, never by typing a number**, once both sets of
surfaces exist.

---

## FIT TO BE SEEN BY A NON-TECHNICAL CEO?

**Yes.**

The path he actually takes is clean end to end. He talks to Rich, an assignment appears, and a
quiet line above the composer says what is happening and whether he is needed. When he is needed it
says "1 needs you" in bold with a mark beside it, and a control named "Review decision" opens the
question in full — never cut, never capped, with its answers under it in the same flow and a
visible control the moment there is more to read. He can stop the work at any size, in either
theme, while any of that is open. If he wants the story he opens one door and gets it in his own
words, with no "verbatim", no "acceptance constraint", no `CEO_DECISION:`, and no command lines.
Every readable thing on that surface is at least 16px and at least 13:1.

Two things stop it being a ten, and both are named above with the measurement that found them: the
account of what happened still cuts itself off without saying so, and the line that tells him he is
needed was quietly moved off the contrast floor that protects it. Neither will embarrass him next
week. Both should be closed before this panel is touched again.

---

*Granted by Urban, Principal Product Designer, 2026-09-06. Score 9/10 against a bar of 9. The two
findings this panel was withheld for are fixed at the root, and I verified them rather than
accepting them. The gaps above are the price of the signoff, not a footnote to it.*
