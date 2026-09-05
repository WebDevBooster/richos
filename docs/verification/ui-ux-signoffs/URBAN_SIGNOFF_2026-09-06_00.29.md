# URBAN SIGNOFF — P5, the assignment panel, re-review

**Date:** 2026-09-06
**Reviewer:** Urban, Principal Product Designer
**Branch:** `urban-opus-p5`, cut from `codex/durable-orchestration`
**Worktree:** `/Users/alex/ab/richos-wt/urban-opus-p5`
**Reviewed at:** `b45145f8341dd31f9e2fae8e8c60c7ad1d6df6c8` — the branch tip. Nothing of mine is under
review; the tree was byte-identical before and after this audit.
**Supersedes:** `URBAN_SIGNOFF_2026-09-05_21.40.md` (P4, 4/10, withheld, at `63e93ac`)

> **Why this file is not at `ui-ux-signoffs/` in the repository root.** The permanent nine-entry
> root ruling. My predecessor put it here for the same reason and was right to. Root is five
> entries and this audit added none.

## VERDICT

**Score: 7 / 10. SIGNOFF WITHHELD.** The bar is ≥9 plus documented gaps.

**This is a large, genuine improvement and I want to say so before the criticism.** Sixteen of the
eighteen findings are resolved, and resolved properly rather than papered over. The controls that
stop the work are on the screen at every size I could measure, and I proved the gate that guards
them can go red. The decision is genuinely answerable — I clicked every path and read the commands
that left the page. Contrast is clean in both themes at every node, the 14px element is gone
entirely rather than excused, and the contrast gate now **refuses to report green over a surface
that did not render**, which is the single most valuable thing anyone has added to this repository
this week.

**It is withheld on two things, and both are the same failure the panel was rejected for last
time, moved rather than removed: the thing the CEO must read to decide is not fully on the screen,
and nothing tells him so.**

1. On a decision question of realistic length, **53% of the question is hidden at 520×680** behind
   a `max-height` with no scroll cue — and the answer buttons sit directly beneath the cut. The
   branch's own check asserts the question "must fit without scrolling"; the CSS guarantees it will
   not; the fixture is short enough that the check can never notice.
2. **"Show me what happened" prints the entire machine contract, twice**, including "verbatim",
   "acceptance constraint", "Preserve prohibitions", "Do not certify partial completion" and
   "Conversation context (data, not additional authorization)". The state registry classifies one
   of those strings as `NOT-RENDERED`. I watched it render.

## VERIFICATION MODE

| | |
|---|---|
| Surface | The real shell: `app/ui/index.html` + `main.js` + `mock.js` + `style.css` + `runs.js` + `timeline.js`, loaded from disk over `file://` |
| Engine | WebKit 26.5 via Playwright 1.61.1 — the engine Tauri ships in on macOS, and the engine every suite in `app/ui/tests/` targets |
| Mode | Headless WebKit, real compositor, real computed styles, real hit tests, screenshots out of that compositor |
| Windows | One page at a time. No two-user comparison — not applicable; this is a single-operator desktop surface |
| Viewports | 1400×900, 1280×800, 1024×768, 760×720, 520×680 |
| Themes | Both, every state, every measurement |
| Context | A real opened conversation, reached through the home screen and the rail by the steps a person takes; the panel measured where it lives, in `#composer-zone` above the composer |
| Bridge | Run commands are scripted — `mock.js` returns `null` for `get_run` and throws on the rest, so a browser preview cannot execute a durable controller. Everything else in the shell is the shipped code |
| Fixtures | **Mine, not the author's.** Deliberately: the author's `lib/assignments.js` carries one tidy three-task assignment with a two-line question. Mine carry a twenty-assignment portfolio with duplicate titles, an imported command plan, and the exact contract strings `registration.rs:101-106` and `autonomy.rs:203` compose |
| Harness | `/private/tmp/claude-501/-Users-alex-ab-femcboost/9befc211-b0af-4e74-b96a-8fcafc7d45ba/scratchpad/p5/` — `fx.js`, `geom.js`, `negctl.js`, `negctl2.js`, `contrast.js`, `ratios.js`, `extra.js`, `stress.js`, `vocab.js`, `shots.js`; screenshots in `shots/` |

**The contrast arithmetic is not mine.** I loaded `app/ui/tests/lib/contrast.js`'s own `pageScript()`
into the page and used its exported math and its hit-test background resolution, so the ratios below
are the numbers this project's own gate produces.

**Every number in this document was read off that live surface.** Anything I could not verify is in
"What I did not check", by name and with the reason.

---

## THE GATES CAN GO RED — I MADE THEM

The bar named eleven instances of a check reporting green over something that never ran. A suite's
green tells me nothing until I have made it fail. Five mutations, each reverted immediately with
`git checkout --`, tree verified clean after every one:

| # | Mutation | Expected | Result |
|---|---|---|---|
| 1 | `#managed-run { max-height: 90px; overflow: auto }` | the viewport check fails | **FAIL** "Every required control is in the viewport at five sizes in both themes" (+2 more) |
| 2 | `.run-checks { font-size: 0.875rem }` | the type floor fails | **FAIL** "Definition of done and file controls are at least 16px" |
| 3 | a new unclassified sentence rendered from `runs.js` | affordances fails and names it | **FAIL**, quoted verbatim, sited at `runs.js:120 runs.js:controls` |
| 4 | **the identical sentence in `app/ui/updates.js`** | affordances should fail | **PASS — "the affordance rule holds."** See gap 4 |
| 5 | `.run-status` not appended | the contrast walk must not pass | **FAIL** ×5, "assignment-running did not measure its required state: run-status", plus "found only 446 text nodes but its floor is 448 — the driver did not reach the state it was written for, so a clean result here proves nothing" |

Mutation 5 is the answer to "are the gate fixes real or cosmetic" for findings 17 and 18: **real, and
better than asked for.** The author did not merely add surfaces to a list; each assignment surface
must prove it measured its own defining node, and the harness holds an independent node-count floor.
That is a structural defense against exactly the failure that hid this panel for months.

**My own geometry probe was proven able to fail three ways** before I trusted a single "visible":
clipped by a scroll container (`blockers: composer-row, input`), pushed below the window
(`belowFold: 782px, offscreen`), and occluded by an opaque sheet with geometry unchanged
(`blockers: div#urban-veil`). An absent selector reports `present: false`, never a pass.

---

## 1. THE STOP CONTROL, MEASURED AT ALL FIVE SIZES — RESOLVED

The P4 defect was Pause and End 62px below a hard 240px cap that did not scale. That cap is gone.
`#managed-run` is `flex: none` with no height limit; the optional history is an absolutely
positioned overlay above the panel; the controls sit in normal flow, outside it.

**Fully visible = all four corners and the middle of the rect inside the viewport AND the topmost
element at those five points is the button.** A hit test, not a look. 80 measurements, 8 states ×
5 sizes × 2 themes:

| State | 1400×900 | 1280×800 | 1024×768 | 760×720 | 520×680 |
|---|---|---|---|---|---|
| running | Pause **HIT-OK** End **HIT-OK** | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK |
| decision (resource) | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK |
| decision (business) | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK |
| twenty assignments | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK |
| paused | absent¹ / HIT-OK | absent¹ / HIT-OK | absent¹ / HIT-OK | absent¹ / HIT-OK | absent¹ / HIT-OK |
| imported plan | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK | HIT-OK / HIT-OK |
| load failure | absent² | absent² | absent² | absent² | absent² |
| empty | absent² | absent² | absent² | absent² | absent² |

¹ Correct: a paused assignment offers Continue and End, not Pause. ² Correct: there is no assignment
to stop. Identical in both themes; `belowFold: 0` on every hit. The composer stayed visible in all 80.

**And the stop controls stay live while a decision is in flight.** With `respond_run_decision`
hanging, the picker, "Keep going" and "Change instructions" gray out; **Pause and End do not**
(`runs.js:155` exempts them by name). That is a deliberate, correct call and it deserves the credit.

**Verification basis: measured live on the target surface, five sizes, both themes, hit-tested, with
a probe proven able to fail three ways.**

## 2. IS THE DECISION GENUINELY ANSWERABLE — RESOLVED

A command existing is not the CEO being able to decide, so I clicked every path and read what left
the page.

| What I clicked | Command the page issued |
|---|---|
| "Keep going" | `respond_run_decision {threadId, runId:"run-aaaa1111", taskId:"task-1", decisionId:"q-resource-1", action:{kind:"continue"}}` |
| "Change instructions" → typed 76 characters → "Send decision" | same identities, `action:{kind:"change_scope", text:"Stop trying to reconcile the ledger. Use the numbers Finance already signed off."}` — **the exact typed text, unaltered** |
| "Describe the change without names" → "Confirm decision" | `decisionId:"q-business-1"`, `action:{kind:"answer", text:"Describe the change without names"}` — the option's exact wording |
| "End assignment" → "Confirm end" | `end_run {threadId, runId:"run-0000beef0"}` — the identity of the row actually selected, out of twenty |

Every call carries assignment, task and question identity. Each destructive or committing action
passes through a confirmation naming its exact target. The resource question no longer begins
`CEO_DECISION:` — `run.rs:937` composes "Rich has used the allowance without finishing." and
"Keep going allows up to 10 more attempts of up to 15 minutes each, plus checks. Provider charges
apply.", and `runs.js:128` filters any evidence line containing the marker out of history.

**This is the finding I was most skeptical of and it is properly done.**

**Verification basis: exercised live, human-paced, by clicking what is on the screen; bridge calls
captured verbatim.**

## 3. WHERE IT STILL FAILS

### 3.1 The question he must read is clipped, with no cue, and the answers sit under the cut

`style.css:4462-4463` caps the question at `max-height: 20vh`, tightening to `15vh` below 760px
window height. The author's fixture question is two short lines and never reaches it. A question a
real model would write does:

| Window | Question box | Content | Hidden | Hidden % | Scrollbar reserved |
|---|---|---|---|---|---|
| 1400×900 | 138px | 138px | 0px | 0% | 0px |
| 1024×768 | 154px | 178px | **24px** | **13%** | **0px** |
| 760×720 | 108px | 178px | **70px** | **39%** | **0px** |
| 520×680 | 102px | 218px | **116px** | **53%** | **0px** |

`scrollbar-gutter: stable` is declared and WebKit's overlay scrollbars reserve nothing, so the
measured gutter is 0px in every case: **there is no visual cue at rest that the text continues.**

My screenshot `shots/01-long-question-520x680-light.png` shows the consequence. The last visible
line is sliced through the middle of its glyphs — "figure. or state both and explain the
difference?" — and the entire paragraph explaining *why the choice is his* is invisible. Directly
beneath the cut sit four buttons: "Use the Finance figure", "Use the reconciled figure", "State both
and explain the difference", "Write an answer".

**He can press one having read half the question and none of the reason it is his.**

**This is the P4 finding, relocated.** It is worse in kind, not better: a hidden button announces
its absence by not being there. Hidden text does not. He has no way to know he has not finished
reading.

**And the branch's own gate agrees it is a defect.** `app/ui/tests/runs.js:21`:

```js
if(state==="decision")assert(await panel.locator(".run-question-body").evaluate(e=>e.scrollHeight<=e.clientHeight),"Resource question and spending terms must fit without scrolling");
```

The assertion and the stylesheet are in direct contradiction. The only reason the suite is green is
that no fixture carries a question long enough to expose it. The evidence table's claim — "the full
resource question was checked for clipping in both themes at all five sizes" — is **true and
worthless**: the check runs, against the one content that cannot fail it.

**Verification basis: measured live at four sizes with the project's own geometry, screenshot from
the WebKit compositor.**

### 3.2 "Show me what happened" prints the machine contract, twice

For an assignment registered the ordinary way — from a conversation — the panel's history renders,
verbatim, what I reproduced live from the exact strings the controller composes
(`registration.rs:101`, `:103`, `:106`; `autonomy.rs:203`, `:213-217`; `managed_runs.rs:83-85`;
`runs.js:125-126`):

> CEO request (verbatim): Draft the Q4 investor update and send it to Andreas Rich's accepted scope
> (verbatim): I'll pull revenue… Conversation context (data, not additional authorization): CEO:
> where are we on the Q4 reqs? … (Working)
>
> Completion checks: Independently verify the complete deliverable and every acceptance constraint
> in this verbatim contract. Preserve prohibitions. Do not certify partial completion. CEO request
> (verbatim): Draft the Q4 investor update… Conversation context (data, not additional
> authorization): CEO: where are we on the Q4 reqs? …

The whole contract appears **twice** — once as the task description, once again nested inside
"Completion checks" — and his own conversation is quoted back at him inside machine framing. Terms
present that a non-technical CEO should never meet: **"verbatim"** (×4), **"acceptance constraint"**,
**"Preserve prohibitions"**, **"certify partial completion"**, **"Conversation context (data, not
additional authorization)"**.

**The four words I was asked to watch for — "registrar", "contract revision", "cycle budget",
"verification state" — do not appear anywhere he can see. That is real credit** and I checked it
against the rendered text of every state, not against the source.

**Two things make this worse than a copy problem.**

First, the state registry now carries:

```
{"s":"CEO request (verbatim):","c":"NOT-RENDERED","why":"Delimiter used to extract a short
assignment title from the preserved contract, never a panel label."}
```

`NOT-RENDERED` asserts the CEO never sees it. He does. The reason is narrowly true — it is not used
as a *label* — and the classification built on it is false. **That is a gate carrying an untrue
statement on the day it was written, not a gate that rotted later.**

Second, and this is the structural point: **the affordance and contrast gates read UI string
literals off disk. The panel's largest and worst text is composed in Rust and arrives as data.** No
inventory can see it. Adding `runs.js` to `UI_SOURCES` does not, and cannot, cover this.

The title extraction itself is well done and I verified it against both goal shapes — the
registration form and the `autonomy::plan` wrapper — and it correctly yields "Draft the Q4 investor
update and send it to Andreas" from both. The defect is `task.description` and `task.checks`, which
are never stripped.

**Verification basis: rendered live in the real shell using the exact strings the controller
composes; traced through `registration.rs` → `autonomy.rs` → `managed_runs.rs` → `runs.js`.**

### 3.3 "1 need you"

`runs.js:49` composes the headline as `` `${waiting} ${labels.needs_input} · ${headline}` `` with
`labels.needs_input = "need you"`. With one assignment waiting — the ordinary case — the most
important line in the panel reads:

> **1 need you · Waiting for your decision**

That is not English. Spoken, which is how this product is meant to be usable, it is "one need you".
It is also redundant: the count says one and the clause after it says the same thing again.

**It is in the author's own committed evidence.** `app/validation/owned-work/urban-decision-narrow-light.png`,
the screenshot chosen to prove the fix, has "1 need you" as its top line. An image proves what the
person framing it chose to show, and this one shows the defect.

At three it reads "3 need you · Working · task 2 of 3", which is fine. One is the common case.

**Verification basis: rendered live in both themes; present in the branch's own committed screenshot.**

---

## CONTRAST — COMPUTED, EVERY NODE, BOTH THEMES

40 walks: 8 states × 2 themes × up to 5 interaction variants (closed, history open, picker open,
scope editor, end confirmation, set-aside confirmation). **0 failures, 0 unresolvable, 0 exemptions
claimed, 0 nodes below 16px.**

**Negative control for that zero.** A green from a walk I have not made fail is worth nothing, so I
re-ran the identical walk with the library's floors raised to 21:1 — `NORMAL`, `LARGE` and
`INDICATOR`, with the substitution asserted to have applied. **36 distinct panel nodes reported
their real ratios.** Silence there would have meant the walk was blind to this panel; it was not.

### Text — floor 4.5:1 (nothing in the panel is large text: every node is 16px, weight 400/600/700)

| Node | Text | Size/W | Dark | Light | |
|---|---|---|---|---|---|
| `p.run-status` | "Working · task 2 of 3" | 16px/600 | **14.55:1** `#dfe4ee` on `#0c1322` | **14.90:1** `#0c1322` on `#eae6dd` | PASS |
| `p.run-status.run-attention` | "1 need you · Waiting for your decision" | 16px/700 | **14.55:1** | **14.90:1** | PASS |
| `p.run-question` | "Rich has used the allowance without finishing." | 16px/600 | **14.55:1** | **14.90:1** | PASS |
| `div.run-question-body > p` | "Keep going allows up to 10 more attempts…" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `details.run-history > summary` | "Show me what happened" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `form.run-editor > p` | "End "…" without completing it?" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `run-history-body > pre` | "Error: Corrupt committed journal" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `run-history-body > p` | "Tell Rich what needs doing…" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `run-history-body > label` | "Import assignment from a file" | 16px/400 | **14.55:1** | **14.90:1** | PASS |
| `span.run-title` | the assignment title | 16px/400 | **13.02:1** `#dfe4ee` on `#141e34` | **17.02:1** `#0c1322` on `#f7f5ef` | PASS |
| `[data-run-picker] > span` | "1 assignment ▾" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `div.run-actions > button` | "Pause assignment" (all action buttons) | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `run-decision button` | "Keep going" (all answer buttons) | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `form.run-editor > button` | "Go back" / "Confirm end" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `div#managed-run > button` | "Refresh assignments" | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-choices > button` | a picker row | 16px/400 | **13.02:1** | **17.02:1** | PASS |
| `.run-choices > button.run-attention` | a picker row needing him | 16px/700 | **13.02:1** | **17.02:1** | PASS |
| `button:disabled` | any control during a mutation | 16px/400 | **6.08:1** | **6.22:1** | PASS |

### Non-text indicators — floor 3:1

| Indicator | Dark | Light | |
|---|---|---|---|
| `textarea` border, 1px `--line-control` | **4.57:1** | **3.35:1** | PASS |
| `.run-attention` 3px left border in `--ink` — the panel's only non-typographic "this needs you" channel | **14.55:1** | **14.90:1** | PASS |
| Keyboard focus ring, `2px solid var(--ink)` at 2px offset, reached by a real Tab press so `:focus-visible` genuinely matched | `rgb(223,228,238)` | `rgb(12,19,34)` | PASS |

**Two things stated so nobody has to re-derive them.**

1. **The shared walk does not check labeled buttons as indicators, by its own declared and reasoned
   bound** (`lib/contrast.js:531-556`): a button that says "Pause assignment" is identified by its
   word, and the word is already held to 4.5:1. Only form fields are checked. I record this as the
   library's stated position, not as a gap in this branch.
2. **The `.run-attention` border is not a control, so no gate measures it.** I measured it here with
   the same arithmetic. It passes comfortably. It is worth someone declaring as
   `data-contrast-role="indicator"` so it stops depending on a reviewer noticing.

### The type floor — resolved, cleanly

The P4 `<small>` at 14px is **gone**, not excused: `#managed-run small { font-size: 0.875rem }` is
deleted and `#managed-run pre` is pinned to `1rem`. "Completion checks: …" — the definition of done —
now renders at **16px**. Across 40 walks in both themes, **zero panel text below 16px**, and
**zero exemptions declared**, so there is no claim of skippability to audit. `contrast-debt.json`
gains seven floor entries and **no new debt signatures** (`"signatures": {}` unchanged).

---

## THE EIGHTEEN FINDINGS

| # | Finding | Verdict | Evidence |
|---|---|---|---|
| 1 | Pause/End off-screen in the running state | **RESOLVED** | 80 hit-tested measurements, 5 sizes × 2 themes; probe proven able to fail 3 ways; gate goes red under mutation 1 |
| 2 | Decision offers no way to decide | **RESOLVED** | Four paths exercised live; commands captured with full identity binding |
| 3 | Headline reports the selected row as the portfolio | **RESOLVED** | "3 need you · Working · task 2 of 3" with 20 loaded, 3 waiting |
| 4 | Raw error text, destructive option first | **RESOLVED** | Friendly status precedes "Refresh assignments"; `Error:` text moved to optional history |
| 5 | Ambiguous target, unconfirmed End | **RESOLVED** | Duplicates carry creation time and a reference; End confirms the exact title before issuing `end_run` |
| 6 | Three nouns for one thing | **RESOLVED** | "Assignment" throughout; "run" gone from every rendered string |
| 7 | 14px on the definition of done | **RESOLVED** | 16px measured; `small` rule deleted; no exemption declared or needed; gate goes red under mutation 2 |
| 8 | argv, workspace path, retry mechanics in front of him | **RESOLVED as specified** | All behind "Show me what happened", and only for imported plans. `["cargo","build","--release"]` still renders as JSON argv — see gap 8 |
| 9 | "Start / continue" fails the spoken-option rule | **RESOLVED** | "Continue assignment". No slash labels remain |
| 10 | State carried by a word alone | **RESOLVED** | `.run-attention` adds weight 700 and a 3px border; not color alone, so the white-label discipline holds |
| 11 | Selector: lead with goal, ellipsis, stable presence, a count | **RESOLVED** | Title first, `text-overflow: ellipsis` confirmed rendering, present at n=1, "20 assignments ▾", pending sorted to positions 1–3 |
| 12 | "Not finished" for an unstarted task | **RESOLVED** | "Not started" |
| 13 | Actions before the explanation | **RESOLVED** | `[role="status"]` is now the first child; set-aside requires explicit confirmation |
| 14 | Pausing changes nothing visible | **RESOLVED** | Live: "Working · task 2 of 3" → "Pausing… · task 2 of 3" → "Paused", controls become Continue/End. Verified against a backend that reports paused on a delay, not one that flips instantly |
| 15 | Fixed 240px height budget | **INVERTED, not resolved** | The cap is gone; growth is now unbounded. The panel reaches **57% of a 1024×768 window** and 56.8% of 520×680 on a realistic decision, against the 38% P4 complained about. See gap 6 |
| 16 | `runs.js` invisible to the affordance inventory | **PARTIALLY RESOLVED** | The hole is plugged and load-bearing (mutation 3 fails, sited by line). The class is not fixed (mutation 4 passes). See gap 4 |
| 17 | Panel absent from the contrast surface list | **RESOLVED, better than asked** | 7 surfaces × 2 themes, each required to prove it measured its defining node; mutation 5 makes 5 checks fail |
| 18 | Two-node `backgroundColor` check | **RESOLVED** | Replaced by the shared `pageScript()` walk; my independent walk of the same surfaces agrees at 0 failures |

**Sixteen resolved, one partially, one inverted.**

---

## DOCUMENTED GAPS, RANKED

**Must fix before the CEO sees this panel:**

1. **The decision question clips with no cue, and the answers sit under the cut.** 53% hidden at
   520×680, 39% at 760×720, 13% at 1024×768, 0px of reserved gutter at every size. **The direction:
   the question does not get a height cap at all.** It is the shortest text in the panel that
   matters most; let it size to its content and cap the *history* instead, which is already an
   overlay and already scrolls. If a cap must exist, it needs a cue that survives overlay
   scrollbars — a fade and a "more" affordance, not `overflow: auto` and hope. And the branch's own
   assertion at `tests/runs.js:21` must be pointed at a question long enough to fail it, or it is
   decoration.
2. **"Show me what happened" must not print the contract.** He needs the task in his own words and
   what happened to it. `task.description` and `task.checks` carry the full machine contract twice
   over. Either strip them at the projection in `managed_runs.rs:83-85` the way `title()` already
   strips the goal, or give `TaskView` a short human description alongside the durable one. The
   durable contract must stay durable; it must not be the thing rendered.
3. **Fix the false `NOT-RENDERED` classification** of `"CEO request (verbatim):"` and audit the other
   `NOT-RENDERED` entries added in this commit for the same error. A classification that is wrong is
   worse than a missing one, because it is a recorded assurance.
4. **`UI_SOURCES` is still a typed list and it still rots.** `index.html` loads ten scripts; the
   list names four. `updates.js` — flagged by my predecessor, and the surface a CEO ruling landed on
   — is still invisible, which mutation 4 proves rather than infers. And `affordances.js:1127` still
   reads "`UI_SOURCES` is index.html, main.js and timeline.js": **a comment that went stale inside
   the very commit that changed the list.** A gate that must be edited whenever a surface is added
   has not been fixed. See the merge note — this is already being done properly elsewhere.
5. **"1 need you."** One-line fix. It is in the branch's own evidence screenshot.

**Should fix:**

6. The panel's share of the window is now larger than the state it replaced: up to **57%**. Nothing
   is hidden by it, so this is not a blocker — but the conversation is what he is reading, and a
   decision that consumes more than half the window while the transcript scrolls away behind it is
   not restraint. Cap the *panel*, not the question.
7. **Raw internal references reach him.** `run-0000`, `run-0009`, `run-0016` appear in the picker
   rows, the headline and the End confirmation. `runs.js:22` appends an 8-character runId slice
   whenever two titles collide — but the creation time alone already separates them in every case I
   drove. Show the reference only when the time is also identical.
8. `["cargo","build","--release"]` is still JSON-encoded argv, now behind a disclosure. That matches
   what P4 asked for and I am not re-charging it. It remains the screenshare embarrassment if he
   ever opens it on an imported plan.
9. **The empty state is bare and its one door is misnamed.** A new account shows "No assignment yet"
   and "▶ Show me what happened" — in a state where nothing has happened — with the sentence that
   explains what the strip is for hidden behind that door. The composer beneath is the real next
   action and it is right there, so this is recoverable rather than broken. But an empty account
   should read as authored, and this reads as a negative statement plus a wrong label.
10. **No committed contrast screenshots for the seven new assignment surfaces.** The other 19
    surfaces each have one in `shots-contrast/`; `assignment-*.png` are untracked and were produced
    fresh by my run. The gate captures them; nothing preserves them.
11. `.run-choices` has no `scrollbar-gutter`, unlike `.run-history-body`. With 20 assignments the
    list is 360px against 775px of content. It reads better than the question does — the eighth row
    is visibly half-cut, which is a real if weak affordance — but it is the same cue problem.

---

## THE ONE DIRECTION

**The panel is now the right shape. Finish it by making the question the thing that cannot be cut.**

P4's direction was "stop building a plan viewer and build a status line with one decision in it."
That has been done, and done well: a status line, a chooser, the decision, the controls, and one
optional door for everything else. The remaining defect is that the new structure caps the wrong
element. It pins the buttons and lets the question scroll — and the question is the only part he
cannot act correctly without.

**Invert that one relationship.** The question and its answers size to their content and are never
clipped. The panel as a whole takes a ceiling so it cannot eat the conversation. The history stays
an overlay and absorbs the variance, because he opened it deliberately and it is allowed to be tall.

Gaps 1, 6 and 11 fall out of that single change. Gaps 2 and 3 are a separate, smaller job in the
projection layer, and they are the difference between a panel a non-technical CEO can open and one
he should be told not to.

## WHAT I DID NOT CHECK, AND WHY

- **The Rust evidence: 740 core tests, 42 controller checks, 20/20 mutations, the desktop harness's
  ten phases.** I did not run any of them. Controller correctness is Tom's and Ray's, not mine, and
  a design gate that spends an hour recompiling for mutation testing is not doing its job. **Those
  numbers are unverified by me.** What I did verify is that the *UI* numbers in the same table are
  truthful: 18/18 panel checks, **71** affordance checks, and **52 walks across 26 surfaces**
  confirmed by the suite's own check 10b — every figure matched.
- **The panel inside the shipped Tauri binary.** Reviewed in WebKit 26.5 via Playwright, the engine
  Tauri ships in on macOS and the one every suite here targets. I did not build or run the desktop
  app. **Window chrome, real WKWebView scrollbar behavior and the OS accent color are unverified**
  — and the scrollbar one matters here, because gap 1's severity depends on the operator's
  "Show scroll bars" setting. With classic scrollbars there is a cue; with the macOS default there
  is none. I measured the default.
- **The spoken presentation.** Rich's acknowledgments of panel actions travel through the speech
  path. I read the copy; I did not hear it.
- **Anything about whether the controller does what the receipts say.** I verified the panel issues
  the right command with the right identities. Whether `respond_run_decision` then honors question
  identity, rejects stale questions, or is idempotent on replay is a claim in the response document
  that **I did not test and am not endorsing.**
- **Live provider behavior, very large portfolios beyond 20, and generated option lists longer than
  three.** Named as open by the author; I agree they are open.

## FIT TO BE SEEN BY A NON-TECHNICAL CEO?

**Not yet, and it is close.**

In the ordinary running state, on an ordinary window, this is now a good panel. It says what is
happening, it says whether he is needed, it lets him stop, and it stays out of the way. That was not
true two days ago.

Two sentences still decide it. **On a decision question of the length a real model writes, he can
read half of it and press an answer, and nothing on the screen tells him there was more.** And if he
opens the one door the panel offers him, he gets his own sentence read back to him wrapped in
"verbatim", "acceptance constraint" and "Preserve prohibitions".

Contrast is clean in both themes, every node is at or above 16px, and no exemption is claimed
anywhere. Those were the floors, they are met, and they were never what would have embarrassed him.

---

## MERGE NOTE — THIS BRANCH WILL COLLIDE WITH `echo-opus-gt2`

Recorded because the lead asked, and because the collision is substantive rather than textual.

`echo-opus-gt2` is independently widening the same gates on `main`. It has added a new derived
source manifest at app/ui/tests/lib/ui-sources.js (595 lines) — **written without backticks because
it exists only on that unmerged branch, and a reader with only the public repository would be sent
to nothing**. It **derives** the shipped-source manifest from `index.html`'s `<script src>` and
`<link>` tags, closes over runtime-loaded files, and then **fails by name if any file under
`app/ui/` is missing from the closure**. Its header names the same defect I found, in the same terms.

- **Substance:** gt2's derivation is the correct fix for gap 4 and it supersedes this branch's
  `UI_SOURCES = [..., "runs.js"]` outright. That line should be dropped in the merge, not
  reconciled — gt2's closure already reaches `runs.js`, because `index.html:875` loads it.
- **What must survive from this branch:** the `if (name === "runs.js")` extraction block in
  `state-strings.js:inventory()`, which pulls the twelve state-map labels and the control literals
  past the prose heuristic, and the `explicit` parameter on `add()` that makes it possible. Drop it
  and the labels leave the inventory, which orphans ~50 new `state-registry.js` entries and turns
  the "every classification is a real state" check red. **It should be generalized to every derived
  source rather than special-cased to one filename** — `main.js` and `timeline.js` have state maps
  too, and neither is extracted today.
- **Also colliding:** `lib/state-registry.js` (both add large blocks — additive, should merge),
  `tests/contrast.js` `SURFACES` (both prepend; additive), `tests/affordances.js` `FIXTURES` and
  `TEXT_RENDERING_FIXTURES` (both add; additive), and `contrast-debt.json` floors (additive, and
  **both branches' floors are node counts that will shift once the other's surfaces exist — expect
  the count-floor assertions to need re-baselining after the merge, and re-baseline them by running
  the suite, never by typing a number**).
- **`affordances.js:1127`'s stale comment** should be deleted in whichever lands second.

Judged on its own merits, as instructed. This note changes nothing in the verdict above.

---

*Withheld by Urban, Principal Product Designer, 2026-09-06. Score 7/10 against a bar of 9. The
direction is right and the work is real; two things stop it reaching a non-technical CEO, and both
are named above with the measurement that found them.*
