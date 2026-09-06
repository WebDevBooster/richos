# URBAN SIGNOFF — P7, the assignment panel, follow-up to a GRANTED signoff

**Date:** 2026-09-06
**Reviewer:** Urban, Principal Product Designer
**Branch:** `urban-opus-p7`, cut from `codex/durable-orchestration`
**Worktree:** `/Users/alex/ab/richos-wt/urban-opus-p7`
**Reviewed at:** `9b6c74dc836ea8b7bcb07b2b8d6bd77743c2c50f` — read from `git rev-parse`, never typed.
**Compared against:** `e276ba3b845e66fc7e313e46a637b381241ab7a6`, the revision P6 granted 9/10.
**Reviewed tree:** clean before this audit, clean after it. Nothing of mine is under review.

> **Why this file is not at `ui-ux-signoffs/` in the repository root.** The permanent nine-entry
> root ruling. All three predecessors put it here and all three were right to.

## VERDICT

**Score: 9 / 10. THE GRANTED SIGNOFF STANDS. It is not withdrawn.**

**This was not a re-grant, it was a hunt for a regression, and I did not find one.** Everything
the 9/10 rested on I re-measured from scratch on the live surface rather than assuming it
survived: the question is still uncapped and unclipped at every size in both themes, its answers
still follow it in one flow, every hidden state still carries a reachable cue, the machine
contract is still absent from the account, contrast is still clean in both themes with zero
exemptions and nothing below 16px, and the strip is still under 30% at rest. **Thirty decision
openings, twenty history openings, twenty-six contrast walks, fifty strip measurements. Zero
regressions.**

**The two things P6 withheld nothing for but ranked as must-fix are both closed at the root, and
I proved both rather than accepting them.**

1. **History is a reading surface now, not a box.** `max-height` on `.run-history-body` reads
   **`none`** in all twenty openings. Where content is hidden — eighteen of those twenty — a
   **visible and hit-testable** cue is present, at every size, in both themes, with zero
   exceptions. The screenshot P6 filed as the blocker, six receipts at 520x680 in light, now
   shows the same sliced line **with a visible rule and a "Read more below" control directly
   under it**.
2. **The attention indicator moved off the words, and the empty span really is measured.** This
   is the half that could have been theater and is not. `data-contrast-role` is `null` on the
   status paragraph and on picker attention rows; the empty `span.run-attention-marker` carries
   it, and it turns up **in the walk's `measuredPaths` as a checked indicator** at 14.55:1 (dark)
   / 14.90:1 (light) on the status line and 13.02:1 / 17.02:1 in the picker. I made the mark's
   border equal to its background and the gate went **red at 3:1 in both themes on both hosts**,
   so the measurement is real and not a declaration over nothing.

**And I closed the one claim P6 could not prove.** P6 wrote that the picker attention row's floor
"follows by construction and is not measured", because the chosen ink resolved against the wrong
background. I chose the ink against the surface those rows actually paint on, first proved the
walk can fail on that node at all, and then caught the attention row and a matched plain-row
control at the same ink in both themes. **The picker rows are held to 4.5:1. That is measured
now, not inferred.**

**What keeps this at 9 rather than 10 is the same surface it has always been, for a smaller
reason.** "Show me what happened" is reachable, honest and readable — and its hierarchy is flat.
Four lines of identical weight per step, and on the ordinary conversation-registered assignment
the account now **opens with the bare words "Checks passed" attached to nothing**, because the
fix that correctly removed the duplicated description left the state token standing alone. That
is a new gap, it was created by a correction I asked for, and it is ranked first below.

---

## VERIFICATION MODE

| | |
|---|---|
| Surface | The real shell: `app/ui/index.html` + `main.js` + `mock.js` + `style.css` + `runs.js` + `timeline.js`, loaded from disk over `file://` |
| Engine | WebKit via Playwright (`/Users/alex/ab/deeply/node_modules/playwright`) — the engine Tauri ships in on macOS and the one every suite in `app/ui/tests/` targets |
| Mode | Headless WebKit, real compositor, real computed styles, real hit tests, real clicks and key presses, screenshots out of that compositor |
| Windows | One page at a time. No two-user comparison — not applicable; this is a single-operator desktop surface |
| Viewports | 1400x900, 1280x800, 1024x768, 760x720, 520x680 |
| Themes | Both, every state, every measurement |
| Context | A real opened conversation, reached through the home screen and the rail the way a person reaches it; the panel measured where it lives, in `#composer-zone` above the composer |
| Bridge | Run commands are scripted — `mock.js` cannot execute a durable controller in a browser. Everything else in the shell is the shipped code |
| Backend text | **Not scripted.** `cargo run -p richos-core --example run_view_probe` was compiled and executed and its **four** serialized views were rendered in the shell and read off the screen |
| Fixtures | The author's `lib/assignments.js`, plus mine: six-receipt autonomous assignment, eight-step imported plan with a failing step, twenty-assignment portfolio, single task with an amendment, and the Rust probe's older-format journal |
| Harness | `/private/tmp/claude-501/-Users-alex-ab-femcboost/9befc211-b0af-4e74-b96a-8fcafc7d45ba/scratchpad/p7/` — `hist.js`, `neg.js`, `gate.js`, `gate2.js`, `geom.js`, `copy.js`, `contrast.js`, `histcontrast.js`, `rule.js`, `render-real.js`, `kbd.js`, `kbd2.js`, `kbd3.js`, `shots.js`; screenshots in `shots/` |

**The contrast arithmetic is not mine.** I loaded `app/ui/tests/lib/contrast.js`'s own `pageScript()`
into the page and used its exported math and its hit-test background resolution, so every ratio
below is the number this project's own gate produces.

**Every number in this document was read off that live surface.** Anything I could not verify is
in "What I did not check", by name and with the reason.

---

## THE PROBES CAN FAIL — I MADE THEM, BEFORE I TRUSTED A SINGLE GREEN

The lead's warning was specific and it was the right one: a harness whose **needle** has drifted
reports nothing wrong while proving nothing. My history probe keys on `data-run-more`,
`data-run-previous`, `data-run-retry` and `.run-history-task`. So every one of those was
deliberately broken first.

| # | Mutation to the live page | Result |
|---|---|---|
| 0 | none (baseline) | `hidden:898, pct:71.3, maxH:none, moreVisible:true, moreHit:true` |
| 1 | Delete the `[data-run-more]` cue button | `moreVisible:false, moreHit:false` — an absent marker never reports a pass |
| 2 | Empty `.run-history-body`'s text | **`NOTHING RENDERED — measurement void`** |
| 3 | Remove `.run-history-panel` entirely | **`NOTHING RENDERED — measurement void`** |
| 4 | `#managed-run{display:none}` | **`NOTHING RENDERED — measurement void`** |
| 5 | Re-impose the OLD shape: `max-height:40vh; overflow:auto` with the cue hidden | `maxH:307.2px, moreVisible:false` — the pre-fix defect is caught |
| 6 | Opaque `div#urban-veil` over the viewport, geometry unchanged | `moreVisible:true, moreHit:**false**, blocker:"urban-veil"` |
| 7 | Everything reverted | **byte-identical to line 0** |

**And the specific trap: an absence assertion passing over a surface that never rendered.** Every
open measurement in this audit carries a positive-content control — the body has text AND at least
one `.run-history-task` AND non-zero height AND the panel has non-zero height — proven able to
fail three separate ways above. **Across 20 history openings, 30 decision openings and 26 contrast
walks: zero control voids.** No green below is green over a surface that did not render.

**The contrast walk is not blind to this panel either.** Re-running the identical 26 walks with
`NORMAL`, `LARGE` and `INDICATOR` substituted to 21:1 (substitution asserted to have applied, 3/3
sites, or the run throws) produced **894 failures reporting their real ratios**. Silence there
would have meant the walk never reached the panel.

### The branch's own gate is load-bearing — five mutations of the SHIPPED source

Applied to app/ui/runs.js (on the unmerged branch `codex/durable-orchestration`; without backticks because it does not exist on `main` yet) / `app/ui/style.css` on this unmerged branch, each asserted to have
applied (the script throws if the needle drifted), each reverted immediately, hashes verified.

| # | Mutation | `node app/ui/tests/runs.js` |
|---|---|---|
| 1 | Put `dataset.contrastRole = "indicator"` back on the text-bearing element | **1 red** — "Attention text stays on the text floor and its separate mark stays on the indicator floor" |
| 2 | Delete the `data-run-more` marker, leave the button rendering | **6 red**, including both new history checks |
| 3 | Unwrap history from `readingPanel()`, back to a raw body | **2 red** — both history checks |
| 4 | `border-left: 0` on the mark, so there is nothing to measure | **1 red** — the "the empty mark must actually be measured" assertion |
| 5 | Rename the dismissal back to "Close" | **1 red** — "Dismissal has one unambiguous name and reading cues sit at the cut edge" |

**Mutation 4 is the one that matters.** The gate does not merely declare the mark; it asserts the
mark appears in `measuredPaths`, and a mark with nothing to measure turns that check red. That is
the difference between a contrast declaration and a contrast check, and this branch is on the
right side of it.

`shasum` on both files before and after the whole mutation series: identical
(`b26a95c5…` / `e08f728a…`).

---

## 1. HISTORY GEOMETRY — ALL FIVE SIZES, BOTH THEMES, TWO FIXTURES

Dark and light produced byte-identical geometry, so one table serves both and I state that rather
than printing it twice. `max-height` on the body is **`none` in all twenty openings**. The panel
fits the window (`top >= 0`, `bottom <= innerHeight`) in all twenty. Measured scrollbar gutter: 0
at every size, which is why the cue rather than the scrollbar is doing the work.

### The ordinary path — one autonomous task, six receipts

| Window | Body visible / content | Hidden | Panel share | Cue visible **and** hit-testable | Presses to the end |
|---|---|---|---|---|---|
| 1400x900 | 388 / 388 | **0px** | 49.6% | not needed | 0 |
| 1280x800 | 381 / 408 | 27px (6.6%) | 60.0% | **yes / yes** | 1 |
| 1024x768 | 362 / 548 | 186px (33.9%) | 60.0% | **yes / yes** | 1 |
| 760x720 | 333 / 428 | 95px (22.2%) | 60.0% | **yes / yes** | 1 |
| 520x680 | 309 / 568 | 259px (**45.6%**) | 60.0% | **yes / yes** | 2 |

P6 measured this same shape hiding 45.5% at 520x680 **with zero cues at every size**. The hidden
fraction is unchanged; what changed is that the panel now says so.

### The imported plan — eight steps, one `needs_attention`, a Retry under the cut

| Window | Body visible / content | Hidden | Cue visible / hit-testable | Retry at rest | Presses to reach it | Retry after that |
|---|---|---|---|---|---|---|
| 1400x900 | 441 / 1240 | 799px (**64.4%**) | yes / yes | clipped, not hit-testable | 3 | **visible, hit-testable** |
| 1280x800 | 381 / 1240 | 859px (69.3%) | yes / yes | clipped, not hit-testable | 3 | **visible, hit-testable** |
| 1024x768 | 362 / 1260 | 898px (71.3%) | yes / yes | clipped, not hit-testable | 4 | **visible, hit-testable** |
| 760x720 | 333 / 1240 | 907px (73.1%) | yes / yes | clipped, not hit-testable | 4 | **visible, hit-testable** |
| 520x680 | 293 / 1420 | 1127px (**79.4%**) | yes / yes | clipped, not hit-testable | 5 | **visible, hit-testable** |

**I am stating this plainly rather than rounding it in the branch's favor: the Retry control is
still not visible at rest at any of the five sizes in either theme.** What has changed is that it
is no longer *silent*. P6's charge was twelve wheel notches inside an overlay with no cue, no
toolbar and no gutter — a control that was undiscoverable. It is now three to five presses of a
named control that is visible and hit-testable the moment there is anything below the cut, in
every one of the ten imported cases. **That is exactly the standard the decision meets** (its last
answer is one to five presses away in the same stress cases), and demanding every control in an
eight-step plan be visible at rest would mean an unbounded panel. The residual — that the cue says
"there is more to read" and not "there is something to do down there" — is ranked below as gap 2.

Escape closes the panel and returns focus to the `Show me what happened` summary; three
consecutive summary clicks leave exactly one panel and no page errors.

**Verification basis: measured live on the target surface, five sizes, both themes, hit-tested,
with a probe proven able to fail seven ways and a positive-content control proven able to fail
three.**

---

## 2. THE INDICATOR FIX — BOTH HALVES, PROVEN

### (a) The words kept the 4.5:1 text floor

Ink forced to a value **strictly between the two floors**, chosen against the background each node
actually resolves against, with a matched control that carries no mark.

| Theme | Node | `data-contrast-role` | Ink forced to | Computed ratio | Shared gate |
|---|---|---|---|---|---|
| dark | `p.run-status.run-attention` — "1 needs you" | **none (self and ancestor)** | `#636363` on `#0c1322` | **3.09:1** | **CAUGHT at 4.5** |
| dark | `p.run-status` — "Working · task 2 of 3" (control) | none | `#636363` on `#0c1322` | **3.09:1** | **CAUGHT at 4.5** |
| light | `p.run-status.run-attention` — "1 needs you" | **none** | `#6a6a6a` on `#eae6dd` | **4.34:1** | **CAUGHT at 4.5** |
| light | `p.run-status` (control) | none | `#6a6a6a` on `#eae6dd` | **4.34:1** | **CAUGHT at 4.5** |
| dark | `.run-choices button.run-attention` | **none** | `#6a6a6a` on `#141e34` | **3.07:1** | **CAUGHT at 4.5** |
| dark | `.run-choices button` (control) | none | `#6a6a6a` on `#141e34` | **3.07:1** | **CAUGHT at 4.5** |
| light | `.run-choices button.run-attention` | **none** | `#737373` on `#f7f5ef` | **4.35:1** | **CAUGHT at 4.5** |
| light | `.run-choices button` (control) | none | `#737373` on `#f7f5ef` | **4.35:1** | **CAUGHT at 4.5** |

**The picker rows needed a can-fail control before any of that meant anything, and they got one.**
My first attempt reported both rows GREEN — and it was my probe, not the branch: the failure key
is a style signature (`button.run-attention | fg on bg | 16px/700 | >=4.5`), which contains no
path, so filtering the keys for "run-choices" matched nothing. **A filter that matches nothing
reports no failures.** I caught it by forcing the ink to equal the row's own background: that must
produce a failure and did not, which is what a can-fail control is for. Filtering on the entry's
`selector` instead produced the eight rows above. P6's one unproven claim is now proven.

### (b) The empty mark is really measured, not merely declared

`span.run-attention-marker`: 3px wide (the border's own box), 16px tall in the status line and
28px in a picker row, `display:block`, `visibility:visible`, `textContent` empty,
`aria-hidden="true"`, `data-contrast-role="indicator"`.

| Theme | Mark | In `measuredPaths` | Real ratio (floor raised to 21 so it reports) | Border == background |
|---|---|---|---|---|
| dark | status line | **yes, as `(indicator)`** | **14.55:1** on `#0c1322` | **CAUGHT at 3:1** |
| light | status line | **yes** | **14.90:1** on `#eae6dd` | **CAUGHT at 3:1** |
| dark | picker attention row | **yes** | **13.02:1** on `#141e34` | **CAUGHT at 3:1** |
| light | picker attention row | **yes** | **17.02:1** on `#f7f5ef` | **CAUGHT at 3:1** |

`aria-hidden="true"` does not remove it from the walk — the indicator pass keys on the `CONTROLS`
selector, which includes `[data-contrast-role='indicator']` explicitly, and only skips
`display:none`, non-`visible`, sub-1px or fully transparent nodes. The mark is none of those. **22
marker measurements across the 26 walks**, in every state where an attention mark exists.

**Verification basis: mutated live in the real shell; ratios computed with the project's own
arithmetic; matched controls in both themes on both hosts; a can-fail control run first.**

---

## CONTRAST — COMPUTED, EVERY NODE, BOTH THEMES

26 walks: 13 states x 2 themes (empty, running, decision, long question, eightfold question, load
failure, history closed, history with six receipts and an amendment, history of an eight-step
imported plan, history of the older-format journal, picker, twenty-row picker, scope editor).

**1,690 text nodes checked. 98 indicators checked. 0 failures. 0 unresolvable. 0 exemptions
claimed. 0 panel text nodes below 16px. 0 positive-content voids.**

Every ratio below is the shared library's own arithmetic, read out by raising its floor to 21:1 so
each measured node reports its true number.

### Text — floor 4.5:1 (nothing in the panel is large text; every node is 16px at weight 400/600/700)

| Node | Text | Size/W | Dark | Light | |
|---|---|---|---|---|---|
| `p.run-status` | "Working · task 2 of 3" / "Working" / "Completed" / "No assignment yet" | 16px/600 | **14.55:1** `#dfe4ee` on `#0c1322` | **14.90:1** `#0c1322` on `#eae6dd` | PASS |
| `p.run-status.run-attention` | "1 needs you" | 16px/700 | **14.55:1** | **14.90:1** | PASS |
| `p.run-status.run-attention` | "3 need you · Working · task 2 of 3" | 16px/700 | **14.55:1** | **14.90:1** | PASS |
| `p.run-status.run-attention` | "Rich couldn't update this assignment…" | 16px/700 | **14.55:1** | **14.90:1** | PASS |
| `div#managed-run > p` | "Tell Rich what needs doing in the conversation…" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `details.run-history > summary` | "Show me what happened" / "Import an assignment" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `.run-history-task > p` | the task description, and the state line | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `.run-history-task > p.run-checks` | "What Rich agreed to deliver: …" / "Completion checks: …" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `.run-history-task > p.run-receipt` | a receipt, x6 | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `.run-previous-instructions > p` | "Your request: …" / "Rich agreed: …" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `.run-question` / `.run-question-body > p` | the decision and its reasoning | 16px/600, 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `form.run-editor > p` | "What should Rich do differently?…" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `details > summary` (nested) | "Technical details" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `div.run-actions > button` | "Review decision" / "Pause assignment" / "End assignment" / "Continue assignment" | 16px/400 | **13.02:1** `#dfe4ee` on `#141e34` | **17.02:1** `#0c1322` on `#f7f5ef` | PASS |
| `div#managed-run > button` | "Refresh assignments" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-picker > button > span.run-title` | the title, plain / date-qualified / "Saved assignment" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-picker > button > span` | "1 assignment ▾" / "20 assignments ▾" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-reading-controls > button` | "Back to conversation" / "Read more above" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-reading-next > button` | "Read more below" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-decision .run-actions > button` | "Keep going" / "Use approved approach N" / "Write an answer" / "Change instructions" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-choices > button` | a picker row | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-choices > button.run-attention` | a picker row needing him | 16px/700 | **13.02:1** | **17.02:1** | PASS |
| `form.run-editor > button` | "Go back" / "Confirm end" / "Confirm decision" / "Send decision" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `button:disabled` | any control during a mutation | 16px/400 | **6.08:1** | **6.22:1** | PASS |

### Non-text indicators — floor 3:1

| Indicator | Dark | Light | |
|---|---|---|---|
| `span.run-attention-marker`, 3px `--ink`, the NEW element carrying the declaration | **14.55:1** `rgb(223,228,238)` on `#0c1322` | **14.90:1** `rgb(12,19,34)` on `#eae6dd` | PASS |
| same, inside a picker attention row | **13.02:1** on `#141e34` | **17.02:1** on `#f7f5ef` | PASS |
| `.run-reading` panel boundary, 1px `--line-control`, against what is actually painted behind it | **4.57:1** `rgb(107,126,168)` on `rgb(12,19,34)` | **3.35:1** `rgb(118,124,141)` on `rgb(234,230,221)` | PASS |
| **`.run-reading-next` border-top — the NEW cut-edge rule**, measured in the state where it is painted | **4.57:1** `rgb(107,126,168)` on `rgb(12,19,34)` | **3.35:1** `rgb(118,124,141)` on `rgb(234,230,221)` | PASS |
| `textarea` border, 1px `--line-control` | **4.57:1** | **3.35:1** | PASS |
| Keyboard focus ring, reached by a real Tab press so `:focus-visible` genuinely matched | `2px solid rgb(223,228,238)`, offset 2px | `2px solid rgb(12,19,34)` | PASS |

**Three bounds stated so nobody has to re-derive them.**

1. **The cut-edge rule is NOT checked by the shared walk.** `.run-reading-next` is a plain `div`
   with no `data-contrast-role`, so it is outside the `CONTROLS` selector. I measured it directly
   with the library's arithmetic in the state where it is actually painted (520x680, six receipts,
   79px hidden, cue reading "Read more below", gap from the cut edge **0px**) and it clears the
   floor in both themes with room. **It should carry the declaration the attention mark now
   carries** — that is gap 5 below, and it is cheap.
2. **The shared walk does not check labeled buttons as indicators**, by its own declared and
   reasoned bound (`lib/contrast.js:530-556`). I record this as the library's stated position, not
   a gap in this branch.
3. **No exemption is declared anywhere in the panel, so there is no claim of skippability to
   audit, and none is needed** — every readable node is at or above 16px.

### The `obscured` bucket is not a hiding place

40 entries, and **not one of them is a panel node**. Every one is a conversation-timeline node
covered by the panel's own opaque reading overlay — expected, and each is measured on the walks
where that overlay is closed. The suite's own check 11 confirms the same across all 52 shipped
walks.

### The type floor — clean

Across all 26 walks in both themes: **zero panel text nodes below 16px.** Every readable string in
the panel is 16px at weight 400, 600 or 700.

---

## 3. THE ELEVEN CORRECTIONS — VERIFIED OR NOT

| # | Correction | Verdict | Evidence read off the live surface |
|---|---|---|---|
| 1 | History uses the same `readingPanel()` | **RESOLVED** | `max-height:none` in all 20 openings; panel fits in all 20; cue visible **and** hit-testable in all 18 that hide anything; Retry reached in 3–5 presses in all 10 imported cases and hit-testable after; Escape returns focus to the summary. Section 1 |
| 2 | Attention text back on the 4.5:1 floor | **RESOLVED, AND PROVEN ON BOTH HOSTS** | `data-contrast-role` null on self and ancestor; matched controls caught at 4.5 in both themes on both the status line and the picker row — the node P6 could not prove. Section 2(a) |
| — | …and the mark really is measured | **RESOLVED** | In `measuredPaths` as an indicator, 22 times; real ratios 13.02–17.02:1; border==background goes red at 3:1 in both themes. Section 2(b) |
| 3 | **Read more above** replaces **Read previous** | **RESOLVED** | Read off the screen in both themes: `[data-run-previous]` reads "Read more above", `[data-run-more]` reads "Read more below". Zero occurrences of "Read previous" across 12 rendered states. Spoken, "above" and "below" are a true pair and neither can be heard as "the previous assignment" |
| 4 | One dismissal, **Back to conversation**; **Close decision** gone | **RESOLVED** | Exactly one `[data-run-dismiss]` per panel, labeled "Back to conversation"; zero buttons matching /close/i anywhere; "Close decision" absent from all 12 states. **Review decision no longer toggles**: pressed while open it stays open, `aria-expanded` stays `"true"`, and **zero bridge calls are issued** — it cannot commit anything |
| 5 | **What Rich agreed to deliver** replaces the mislabeled check | **RESOLVED** | Autonomous history renders "What Rich agreed to deliver: I'll deliver the complete draft…"; the imported plan still renders "Completion checks: Report has all four sections" for its actual named checks. Both read off the screen, both themes |
| 6 | Amendments split into **Your request** / **Rich agreed** | **RESOLVED** | `.run-previous-instructions` contains exactly two `<p>`: "Your request: Draft the Q4 investor update. Do not send it or contact anyone." and "Rich agreed: I'll deliver the complete draft…", preceded by "Earlier instructions still apply unless changed." on its own line. Both actors are named, so it survives being spoken (§25) |
| 7 | Receipts in the body face | **RESOLVED** | Zero `<pre>` in autonomous history; `p.run-receipt` computes `font-family: Inter, RichOS Symbols, sans-serif`, byte-identical to `#managed-run`'s own; `white-space: pre-wrap`, so line breaks survive |
| 8 | Cue at the cut edge with a visible rule | **RESOLVED** | `.run-reading-next` sits **0.0px** below the body's bottom edge in every state that shows it, carries a 1px `--line-control` rule, and the rule clears 3:1 in both themes. No fade over receipt text — the author declined that half and was right to; a fade over the CEO's own account degrades the thing it decorates |
| 9 | Unknown envelopes fall back to **Saved assignment** | **RESOLVED, THROUGH THE REAL RUST CHAIN** | Compiled and ran `run_view_probe`; it now emits **four** views, the fourth authored independently of today's registrar. Rendered all four in the shipping shell with every nested disclosure opened, and searched the screen for 22 machine terms including the older format's own strings. **Zero hits, all four views, both themes.** The older-format view renders "Saved assignment" / "The saved assignment details are unavailable in this view." / "Saved results are kept with this assignment." — no checks, no command recipe, no raw bytes. `python3 app/scripts/test-assignment-projection-mutations.py`: **3/3 mutations killed, each after a successful compile** |
| 10 | A single task drops its number and its duplicate description | **RESOLVED, WITH A SIDE EFFECT** | One task renders as `<section class="run-history-task">`, zero `<ol>`, and the description is omitted when it equals the goal. **The side effect is gap 1 below** |
| 11 | **Review decision** shares the action row | **RESOLVED, WITH REAL HEADROOM** | 50 resting strip measurements, 5 states x 5 sizes x 2 themes: **max 26.9%, min 11.4%, zero at or above 30%.** The decision-pending strip fell from 198px/29.1% to **164px/24.1%** at 520x680. P6's 0.9 points of headroom is now **3.1**, and the branch's own viewport test injects an extra status line and asserts the strip still clears the budget |

**Eleven of eleven resolved. One created a new gap, ranked first below.**

---

## 4. VOCABULARY, DIALECT, PAGINATION — SWEPT ON THE RENDERED TEXT

Twelve distinct rendered states across two themes — decision open, autonomous history with an
amendment, imported history, empty, load failure with history open, and a twenty-row picker —
searched for 36 terms: withdrawn copy, machine vocabulary, pagination language and non-American
spellings.

**Zero hits.** The sweep's own positive control ("Show me what happened", which is on 10 of the 12
screens) found it on all 10, so the sweep reads the screen rather than an empty string.

**Zero pagination language, zero page numbers, zero page boundaries.** "Read more above" /
"Read more below" step by 80% of the viewport with 20% overlap and the container is a genuine
scroll region — P6 measured that and it has not changed shape, only name. **This is not
pagination and does not need defending as an exception.**

**One deliberate machine string survives and I am not re-charging it:** `Error: Corrupt committed
journal`, inside the opened history in the load-failure state, behind the friendly sentence. P4,
P5 and P6 all accepted that placement.

---

## 5. THE SUITES

Run on this branch from a clean tree, with the tracked screenshots restored afterwards.

| Suite | Result |
|---|---|
| `node app/ui/tests/runs.js` | **27 / 27 PASS** (23 at `e276ba3`; four new checks) |
| `node app/ui/tests/contrast.js` | **PASS** — 52 walks across 26 surfaces, 0 debt hits, 0 new, 0 worsened, **0 exemptions declared in the shipped source** |
| `node app/ui/tests/affordances.js` | **PASS** — "the affordance rule holds" |
| `node app/ui/tests/docs-claims.js` | **PASS** — 6 / 6 |
| `cargo run -p richos-core --example run_view_probe` | **exit 0**, four serialized views |
| `python3 app/scripts/test-assignment-projection-mutations.py` | **PASS** — 3/3 projection mutations rejected, each after a successful compile |

**Tree discipline:** `git status --short` was empty before this audit and is empty after it. The
contrast suite overwrote **19** tracked screenshots — the same 19 pre-existing nondeterministic
surfaces P6 saw, none of them this branch's doing — and all 19 were restored with
`git checkout --`. **The seven `assignment-*.png` reproduced byte-for-byte again**, which is the
second independent confirmation that gap 10 of the P5 list stayed fixed. Five deliberate source
mutations were reverted immediately and both files verified byte-identical by `shasum`.

---

## DOCUMENTED GAPS, RANKED

**None of these blocks the CEO seeing the ordinary path. None of them withdraws the signoff.**

1. **The account of what happened opens with an orphaned status word, and this is new.** On the
   ordinary conversation-registered assignment — one task, description equal to the goal — the
   correction that rightly removed the duplicated description left the state token standing alone,
   so "Show me what happened" opens with the bare words **"Checks passed"** attached to nothing.
   On a task whose description differs, the shape is description, then **"Working"** on its own
   line, then the agreement. Read as a whole it is a sentence fragment where the panel's most
   human moment should be. **Fix: fold the state back into a line that has a subject — "Rich
   finished this and the checks passed", or a labeled status with its own weight — rather than a
   bare token in body copy.** Grant's words, my structure. Verified live in both themes on the
   real Rust projections.
2. **The history cue says there is more to read; it does not say there is something to do.** On
   the imported plan the "Retry after reviewing the result" control is under the cut at all five
   sizes in both themes, three to five presses away. That is a large improvement on P6's twelve
   silent wheel notches and it meets the standard the decision meets. It is still true that a CEO
   who does not press has no way to know an action is waiting. **Fix: when a hidden step carries
   an action, say so in the cue** — one extra clause, no new surface.
3. **Eight steps render as thirty-two lines of identical weight.** Description, state, completion
   checks and receipt are four body paragraphs per step, repeated eight times, with the same check
   sentence on every one. It is readable and it is not a hierarchy. This is the secondary
   (imported) path, not the ordinary one, which is why it is third. **Fix: give the state its own
   weight or position, and collapse a check that is identical across every step to one line at the
   top.**
4. **The one thing that needs him looks exactly like the two things that stop the work.**
   "Review decision", "Pause assignment" and "End assignment" are now one row of three identical
   controls. The headroom win was worth it and the bold "1 needs you" with its mark carries the
   urgency above. But at a glance the primary action has no more weight than the destructive one
   beside it. **Fix: weight or separate the review control within the row; do not move it back
   out.**
5. **Declare the cut-edge rule for measurement.** `.run-reading-next`'s border-top is now a
   load-bearing boundary — it is what tells the eye the text was cut — and the shared walk does
   not check it, because it is an undeclared `div`. It measures 4.57:1 / 3.35:1 today. **Put
   `data-contrast-role="indicator"` on it, exactly as the attention mark now does**, so tomorrow's
   change to `--line-control` is caught rather than discovered.
6. **The panel now relies on an invariant it does not hold.** Moving "Review decision" into the
   action row means it is not rendered when the assignment is `completed` or `canceled` — I
   confirmed with a hand-built fixture that a completed assignment carrying a pending decision
   shows no door to it. **It is unreachable in production and I verified why**: `RunSnapshot::decision`
   returns `None` when `canceled`, and `Completed` requires every task to be `Passed`, so no task
   can be `NeedsDecision`. The panel is correct because Rust guarantees it. Worth a line in the
   suite so a controller change cannot silently remove the door.
7. **"The saved assignment details are unavailable in this view"** is the one fallback line that
   still sounds like software. "In this view" means nothing to him, spoken or read. **"Rich has
   this assignment saved, but not in a form he can show you here"** says the same thing in his
   language. Grant's call.
8. **`human_contract`'s fallback direction is now right, and the note stands anyway.** The
   projection no longer renders raw bytes when the envelope fails to match, and the probe proves
   it against an independently authored older format. Carried forward from P6 only so nobody
   re-opens it as unresolved: it is resolved.

---

## THE ONE DIRECTION

**Make the account read like an account.**

The panel's shape is now right and I would not change it. Compact status line, chooser, a named
door to the decision, the controls that stop the work, one door to the story — and all three
reading surfaces behave identically, which is exactly what P6 asked for and did not get. The
displacement that defined the last three reviews did not happen a fourth time; I looked for it
with a probe I first broke seven ways, and the history now measures the same as the decision at
every size in both themes.

**What is left is not structure, it is prose.** Behind that last door, the CEO gets four flat
paragraphs per step and a status word with no subject. Everything the panel does to earn his trust
on the way in — the named door, the bold line that says he is needed, the mark beside it — stops
at that threshold. Gaps 1, 3 and 7 are one job: give the history a voice and a hierarchy, the way
the decision already has one. Gap 2 is the same job seen from the other side: an account that
knows an action is waiting should say so.

**Gap 5 is small and it is not optional.** The cut-edge rule is now the thing that tells him text
was cut, and nothing checks it. That is precisely the class of defect this branch just fixed twice
— a boundary that carries meaning and no gate.

---

## WHAT I DID NOT CHECK, AND WHY

- **The panel inside the shipped Tauri binary.** Reviewed in WebKit via Playwright, the engine
  Tauri ships in on macOS and the one every suite here targets. I did not build or run the desktop
  app. **Window chrome, real WKWebView scrollbar behavior and the OS accent color are unverified.**
  Measured scrollbar gutter here was 0 at every size, which is the macOS default and the harder
  case; with "Show scroll bars: Always" the panel gains a gutter it does not need.
- **Real keyboard operability.** Headless WebKit follows the macOS default, which tabs only to
  links and form fields, **not to `<button>` elements** — I confirmed this is global by planting a
  fresh button outside the panel and watching Tab skip it too, so it is an environment fact and
  not this branch's doing. What I could verify: the DOM order inside the panel is correct
  (dismissal, upward cue, reading body, its controls, downward cue, action row, history summary),
  Escape closes each surface and returns focus to the control that opened it, and the focus ring
  is 2px `--ink` at 2px offset in both themes. **Operability with macOS Full Keyboard Access on is
  unverified by me.**
- **The Rust suite beyond the projection probe and its mutation harness.** I compiled and ran
  `run_view_probe` and `test-assignment-projection-mutations.py` because their output is display
  text and display text is mine. I did not run `cargo test -p richos-core`, the controller
  mutations, or the desktop harness. **Those numbers are unverified by me** — they are Tom's and
  Ray's.
- **Whether the controller honors what the panel sends.** I verified the panel issues
  `retry_run_task` with the right assignment and task identity after the reading control uncovers
  it, and that "Review decision" issues nothing at all. Whether the controller rejects a stale
  question or is idempotent on replay is a claim in the response document that **I did not test and
  am not endorsing.**
- **The spoken presentation.** I read every string and judged it as spoken. **I did not hear it.**
- **The nine `NOT-RENDERED` classifications on Echo's home and splash surfaces.** Out of scope for
  this panel; P6 spot-checked two and found both honest, and I did not re-audit the other seven.
- **Portfolios beyond twenty, generated option lists beyond twelve, receipt counts beyond thirty,
  and live provider behavior.** Named as open by the author; I agree they are open.

---

## FIT TO BE SEEN BY A NON-TECHNICAL CEO?

**Yes — and more so than at `e276ba3`.**

The path he takes is unchanged and still clean. What changed is the part that used to fall away
quietly. When he opens "Show me what happened" the panel now behaves exactly like the decision and
the chooser: it never caps itself, it never hides a line without a rule and a named control right
at the cut, and Escape puts him back where he was. The one line that tells him he is needed is
bold, marked, and back on the contrast floor that protects it — with the mark itself measured at
14.55:1 and 14.90:1 rather than merely declared. Every readable thing on the surface is at least
16px and at least 13:1 in both themes, with no exemption claimed anywhere.

What is left is a voice problem, not a structure problem: behind that last door the account still
reads like fields rather than sentences, and it opens with a status word attached to nothing. That
will not embarrass him next week. It is the difference between a panel he trusts and a panel he
enjoys, and it is the whole of the distance from 9 to 10.

---

*Reviewed by Urban, Principal Product Designer, 2026-09-06. **Score 9/10 against a bar of 9. The
signoff granted at `e276ba3` STANDS at `9b6c74d` and is not withdrawn.** Both must-fix findings are
closed at the root and I proved them rather than accepting them, including the one my predecessor
could not prove. The gaps above are the price of the signoff, not a footnote to it.*
