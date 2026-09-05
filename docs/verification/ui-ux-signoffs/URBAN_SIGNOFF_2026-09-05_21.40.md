# URBAN SIGNOFF — P4, the Work plan panel

**Date:** 2026-09-05
**Reviewer:** Urban, Principal Product Designer
**Branch:** `urban-opus-p4`, cut from `codex/durable-orchestration`
**Worktree:** `/Users/alex/ab/richos-wt/urban-opus-p4`
**Reviewed at:** `63e93acb82588c999b979d8d0d76ca18c1070374` (branch tip and merge-base with `codex/durable-orchestration` — nothing of mine is under review)

> **Why this file is not at `ui-ux-signoffs/` in the repository root.** The brief named that path and
> also carried, in bold, "NEVER add an entry to the repository root". The two conflict; the bold
> constraint wins, and the permanent nine-entry root ruling says the same thing. The filename is
> unchanged and this is the only deviation from the brief.

## VERDICT

**Score: 4 / 10. SIGNOFF WITHHELD.** The bar is ≥9 plus documented gaps. This is not close, and the
merge waiting on this review is not an argument for a passing grade.

**Contrast is clean and the type floor is numerically met.** Those were the two things I was pointed
at, and both hold — I computed every one of them rather than trusting the branch's two numbers, and
the panel is the first surface in this shell to be walked by the project's own contrast library at
all. **The panel fails on what it is FOR.** In the state the CEO will see most often, the control
that stops the work is not on the screen and nothing says it exists. In the state that is the whole
reason the panel has authority — work stopped, waiting on him — there is no way to decide, and the
options he is offered are printed as raw machine text beginning `CEO_DECISION:`.

## VERIFICATION MODE

| | |
|---|---|
| Surface | The real shell: `app/ui/index.html` + `main.js` + `mock.js` + `style.css` + `runs.js`, loaded from disk |
| Engine | WebKit via Playwright 1.61.1 — the engine Tauri ships in on macOS, and the same engine `app/ui/tests/` runs against |
| Mode | Headless WebKit, real compositor, real computed styles, real screenshots out of that compositor |
| Windows | One page at a time. No two-user comparison — not applicable, this is a single-operator desktop surface |
| Viewports | 1400x900, 1280x800, 1024x768, 760x720, 520x680 |
| Themes | Both, every state, every measurement |
| Context | A real opened conversation, reached through the home screen and the rail by the same steps a person takes; the panel measured where it actually lives, in `#composer-zone` above the composer |
| Bridge | The run commands are scripted, because `mock.js` returns `null` for `get_run` and throws on the rest — a browser preview cannot execute a durable controller. Everything else in the shell is the shipped code |

**What that means for the claims below.** Every layout, size, color, ratio, clipping and control-position
number in this document was read off that live surface. The panel's data comes from scripted snapshots
shaped exactly as `app/STREAMING.md` documents the wire payload, and the decision-state evidence string
is the literal one `app/crates/richos-core/src/run.rs:542` composes. Anything I could not verify is named
in "What I did not check", with the reason.

**Harness:** `/private/tmp/claude-501/-Users-alex-ab-femcboost/9befc211-b0af-4e74-b96a-8fcafc7d45ba/scratchpad/audit/`
(`panel-audit.js`, `ratios.js`, `probe2.js`, `probe3.js`, `probe4.js`), screenshots in `shots/`,
`shots2/`, `shots3/` beside them. The contrast arithmetic is not mine: I loaded
`app/ui/tests/lib/contrast.js`'s own `pageScript()` into the page and used its exported math and its
hit-test walk, so the numbers here are the numbers this project's gate produces.

---

## CONTRAST — COMPUTED, EVERY NODE, BOTH THEMES

The branch reported **13.02:1 and 17.02:1**. Those two figures are correct and they are two nodes: the
`<select>`'s own text against its own `background-color`, resolved by reading `backgroundColor`
directly — a method `lib/contrast.js` explicitly refuses, because it steps over the `background-image`
the same rule paints on that control. I recomputed everything.

### Text

Panel text inherits `--ink` on the conversation surface; the buttons and the select sit on
`--surface-raised`. Floor is 4.5:1 — nothing in the panel is large text (nothing is 24px, nothing is
18.66px bold; every node is 400 weight at 14px or 16px).

| Node | Text | Size | Dark | Light | Floor | |
|---|---|---|---|---|---|---|
| `summary` | "Work plan: Waiting for your decision" | 16px/400 | **14.55:1** `#dfe4ee` on `#0c1322` | **14.90:1** `#0c1322` on `#eae6dd` | 4.5 | PASS |
| `label` | "Assignment" | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `p` | the goal | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `p` | "Workspace: … 900 seconds per attempt." | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `p` | "Pull the quarter's numbers (Checks passed)" | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `small` | "Completion checks: …" | 14px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `summary` | "Commands used to check completion" | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `pre` | `["cargo","test"]` | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `summary` | "Check results" | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `pre` | `CEO_DECISION:Recovery resource limit…` | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |
| `button` | "Retry after inspecting the result" | 16px/400 | **13.02:1** `#dfe4ee` on `#141e34` | **17.02:1** `#0c1322` on `#f7f5ef` | 4.5 | PASS |
| `button` | "Start / continue" | 16px/400 | **13.02:1** | **17.02:1** | 4.5 | PASS |
| `button` | "Pause run" | 16px/400 | **13.02:1** | **17.02:1** | 4.5 | PASS |
| `button` | "End run without completing it" | 16px/400 | **13.02:1** | **17.02:1** | 4.5 | PASS |
| `button:disabled` | "Run active" | 16px/400 | **6.08:1** `#969dab` on `#141e34` | **6.22:1** `#575b64` on `#f7f5ef` | 4.5 | PASS |
| `p[role=status]` | "Error: Corrupt committed journal" | 16px/400 | **14.55:1** | **14.90:1** | 4.5 | PASS |

### Non-text indicators (floor 3:1)

| Indicator | Dark | Light | |
|---|---|---|---|
| `select` border, 1px `--line-control` on the conversation surface | **4.57:1** `#6b7ea8` on `#0c1322` | **3.35:1** `#767c8d` on `#eae6dd` | PASS |
| `button` border, 1px `--line-control` (all five buttons) | **4.57:1** | **3.35:1** | PASS |
| `button:disabled` border | **4.57:1** | **3.35:1** | PASS |
| `select` disclosure arrow — two 5x5px `var(--ink)` wedges on `var(--surface-raised)` | **13.02:1** | **17.02:1** | PASS |
| Keyboard focus ring, `outline: auto 3px`, reached by real Tab presses so `:focus-visible` genuinely matched | `rgb(223,228,238)` | `rgb(12,19,34)` | PASS |

**Two things I am NOT reporting as failures, stated so nobody has to re-derive them.**

1. **The control FILL against its surround is 1.12:1 (dark) and 1.14:1 (light).** That is `--surface-raised`
   on the conversation paper, and it is not a defect: WCAG 1.4.11 asks that the control's boundary be
   identifiable, the 1px border does that at 4.57:1 / 3.35:1, and `lib/contrast.js` itself takes the
   **best** of fill and border (`contrast.js` line 622-627). My first pass flagged it; the standard
   and the project's own library both say it passes. Recorded because a stricter checker will find it again.
2. **The `<select>` arrow figure above is computed from the declared tokens, cross-checked against the
   measured resolved values.** `#managed-run select` paints the wedges in `var(--ink)` over
   `background-color: var(--surface-raised)`, which is byte-identical to the button text/background
   pairing I measured directly at 13.02 / 17.02. My probe's own read of the custom property came back
   unparseable, so the number is derived rather than sampled. It is the same pair; it is not a guess.

### The 14px `<small>` — the declared exemption is NOT declared, and it is not honest

The brief told me a `small` element sits at 14px "as a DECLARED exemption". **There is no declaration.**
I looked in all four places one could be:

- `app/ui/style.css:4451` is `#managed-run small { font-size: 0.875rem; }` — a bare rule, no comment, no reason.
- No `data-contrast-exempt` anywhere in `app/ui/*.js`, `*.css` or `*.html` — that is the mechanism
  `lib/contrast.js` reads, and it is the mechanism the standing rule's "declared where a reviewer will
  see it" points at.
- Nothing in `runs.js`, which builds the element.
- Nothing in any of the six commit messages on this branch.

The only artifact resembling one is a check in the work-plan UI suite — the file is app/ui/tests/runs.js **on the unmerged branch `codex/durable-orchestration`, deliberately written without backticks because it does not exist on `main` and a reader with only the public repository would be sent to nothing. This entire review is of a branch that has not landed** — namely its check **"Readable work-plan text and
controls meet the type floor"**, which asserts the `small` is `>= 14`. That asserts it clears the
*skippable* floor. It never claims the text is skippable. **That is an exemption wearing a justification,
which is the exact shape the standing rule names.**

And the claim would be false if it were made. The text is **"Completion checks: The figures match the
ledger"** — the definition of *done* for that task. It is the one line in the panel that tells the CEO
what Rich will accept as finished before Rich accepts it. That is not fine print; it is the trust
surface. **`ceo-decisions.md` §15's 16px minimum for text meant to be easily read applies, and this
breaches it.** Contrast is fine at 14.55:1 / 14.90:1; the size is not.

---

## THE THREE PROBLEMS THAT MAKE THIS A FAIL

### 1. In the ordinary running state, the control that stops the work is off the screen — and nothing says so

Measured on a three-task assignment, in every window size I tried:

```
window 1400x900 / 1280x800 / 1024x768 — all identical
  panel visible height    240px   (hard cap, #managed-run > details[open] { max-height: 240px })
  panel content height    310px
  hidden below            70px
  scrollbar width         0px     <- nothing is reserved, nothing is drawn at rest
  "Pause run"                     fully visible: false, 62px below the panel's bottom edge
  "End run without completing it" fully visible: false, 62px below the panel's bottom edge
```

The cap does not scale with the window, so a bigger monitor does not fix it. Overlay scrollbars mean
there is no visual cue at rest that the strip scrolls. The CEO's own statement of what this panel is
for ends with **"and to stop something"**, and in the default case he cannot see the thing that stops it.

Every state I drove is clipped: 32px hidden at 1400x900 on the decision state, 72px at 760x720, 132px
at 520x680. At 520px the panel eats 261 of 680 vertical pixels — 38% of the window — to show a goal
sentence twice and one task.

**Verification basis: measured live on the target surface, three window sizes, both themes.**

### 2. "Waiting for your decision" offers no decision, and prints the options as machine text

This is the state the panel exists for. What renders (live, dark theme, screenshot
`shots/05-needs-decision-dark-top.png`):

```
▼ Work plan: Waiting for your decision
Draft the Q4 investor update and send it to Andreas
  1. Write the update in the CEO's voice (Waiting for your decision)
     Completion checks: Reads as the CEO, not as an assistant
     ▼ Check results
     CEO_DECISION:Recovery resource limit reached: 10 cycles without verified completion.
     This assignment remains owned. Authorize up to 10 further cycles, change its scope
     or end it. Recommendation: review the failure evidence before authorizing more
     compute. Each cycle permits at most one 900-second worker plus independent checks;
     actual charges depend on the provider. Further inference is suspended until your
     [clipped mid-sentence]
  [Pause run]  [End run without completing it]   <- both below the fold
```

Four separate failures stacked in one state:

- **`CEO_DECISION:` is a machine marker.** `app/crates/richos-core/src/autonomy.rs:15` defines it as
  `"CEO_DECISION:"` and `run.rs:542` prefixes it to the sentence; `runs.js` renders `task.evidence`
  verbatim in a `<pre>`. A raw enum tag with an underscore and a colon is the first thing he reads.
- **The vocabulary is the system's, not his.** "Recovery resource limit", "10 cycles", "900-second
  worker", "independent checks", "further inference is suspended". Sage measured the failure-report
  copy and found it clean of component names; **this copy is not held to that bar, and it should be.**
- **The three options are prose inside a collapsed disclosure.** "Authorize up to 10 further cycles,
  change its scope or end it" — of those three, exactly one ("end it") has a control anywhere in the
  panel, and it is off-screen. The other two have none. **A state the user can change must render the
  control that changes it**; this one renders none of them.
- **The whole thing is behind "Check results", closed by default.** The panel's only account of why
  his authority is needed is one click and one scroll away, and the sentence is cut off.

The decision is in fact answered in the conversation — `owned_work.rs:456` publishes a notice and
Rich asks — which is a defensible design for a voice-first product. **The panel never says so.** It
says "Waiting for your decision" and then offers him nothing, which reads as a dead end rather than
as a hand-off.

**Verification basis: rendered live on the target surface with the literal evidence string
`run.rs:542` composes; screenshot captured from the WebKit compositor.**

### 3. It reports the selected assignment's state as though it were the whole picture

With twenty assignments loaded, three of them waiting on his decision, the headline reads:

> ▼ Work plan: Working

Because the summary reports `current.state` — the state of whichever row the `<select>` happens to
have selected. He glances at the strip, it says everything is fine, and three jobs are stalled on him.
There is no count, no "3 need you", no ordering that puts them first — the selector is in backend
order, so the ones needing him land at positions 2, 10 and 18. **For a panel whose stated job is
"what is waiting on him", that is the failure that matters most.**

And the state is carried by nothing but a word. No color, no icon, no weight: "Working" and "Waiting
for your decision" are the same 16px, weight 400, same ink, same position. At a glance — which is how
a strip above the composer is read — they are indistinguishable.

**Verification basis: measured live, 20-assignment fixture, both themes; screenshot
`shots/11-selector-twenty-light-top.png`.**

---

## THE SELECTOR SPECIFICALLY

It is the newest surface, so it gets its own section. It is 16px in both themes (asserted by the
branch, confirmed by me), its text and its border and its arrow all clear the floor, and its keyboard
focus ring is real. The problems are all product problems.

- **Duplicate rows are indistinguishable.** In the 20-assignment fixture, three options render the
  identical string `"Paused: Draft the Q4 investor update and send it to Andreas"` and three more
  render `"Working: …"`. The only thing separating them is `runId`, which is never shown. He picks
  one, and the panel gives him no way to know he picked the right one.
- **That is one click from destroying the wrong work.** "End run without completing it" has **no
  confirmation step**. Ambiguous target plus an unconfirmed destructive control is not a combination
  that ships.
- **The label leads with the wrong half.** `"${state}: ${goal}"` puts the repeated, low-information
  word first and the differentiating sentence second — so at 520px the option truncates to
  `"Waiting for your decision: Prepare the board pack, includ"` and the part that identifies it is
  what gets cut. `text-overflow` is `clip`, so it is a hard cut mid-word with no ellipsis.
- **It appears and disappears.** `assignments.length > 1` gates it. Going from one job to two makes a
  control materialize above the goal; dropping back to one removes it and reflows everything.
- **It says nothing about how many there are.** Twenty assignments look exactly like two until he
  opens it.
- **The selected goal is then repeated verbatim in the `<p>` directly beneath it.** At 520px that
  duplicate sentence is roughly a third of the visible panel.

---

## VOCABULARY THAT REACHES A NON-TECHNICAL CEO

Everything below was read off the live surface. The brief asked whether "registrar", "contract
revision", "cycle budget" or "verification state" leak — **none of those four do, and that is real
credit.** These do:

| What he sees | Where | Why it is wrong |
|---|---|---|
| `CEO_DECISION:` | decision state | Raw enum marker, `autonomy.rs:15` |
| `Error: Corrupt committed journal` | load-failure state | `String(new Error(...))`, `Error:` prefix and all — a developer console line as product copy |
| "Archive the unreadable plan and preserve its journal" | load-failure state | "journal" is a word he does not have, on the most prominent button on the screen |
| `["cargo","build","--release"]` | imported-plan state | JSON-encoded argv in a `<pre>`. This is the screenshare embarrassment |
| `Workspace: /Users/alex/ab/richos. Up to 3 attempts per task, 900 seconds per attempt.` | imported-plan state | A filesystem path and retry mechanics |
| "900-second worker", "independent checks", "further inference is suspended" | decision evidence | The controller's internals |
| **"run"** vs **"work plan"** vs **"assignment"** | throughout | **Three words for one thing, in one panel, at the same time.** "Work plan: Working" / "Assignment" / "Pause run" / "End run without completing it" / "Load another work plan" / "Refresh work plans". Pick one noun |
| "Start / continue" | paused state | Spoken, this is "start slash continue". **`ceo-decisions.md` §25: an option must mean the same read or heard.** It fails that |
| "Not finished" | any un-started task | A task that has not begun is labeled with a failure-shaped phrase. It reads as an accusation, not as "not yet" |

American English: clean. No pagination: clean. No absolute labels in the panel's own copy: clean.

---

## THE THING THAT SHOULD WORRY EVERYONE MOST

**All 23 UI suites pass — 450 checks, 0 failed, 0 skipped — and not one of them can see any of the
above.** I ran the full suite on this branch to confirm it. Three structural blind spots, each verified
by reading the source of the gate itself:

1. **`app/ui/tests/lib/state-strings.js:487` — `const UI_SOURCES = ["index.html", "main.js", "timeline.js"]`.**
   `runs.js` is not in that list. So the affordances suite — whose own README says *"a new
   user-visible string that nobody has classified fails the suite"* and whose headline check is
   **"THE RULE: every ACTIONABLE state names a control"** — is structurally blind to this panel. The
   twelve state labels ("Waiting for your decision", "Retrying automatically", "Not finished", …)
   appear in none of the 577 rows of the derived inventory, and none of them is in
   `lib/state-registry.js`. **The one gate that exists to catch problem 2 above cannot see the panel
   problem 2 is in.** (`updates.js` is missing from that list too; out of my scope, worth someone's.)
2. **`app/ui/tests/contrast.js` walks 20 named surfaces. The Work plan panel is not one of them.**
   Today's run is the first time the project's own contrast walk has ever been pointed at this panel.
   It came back clean — but "clean" was previously being asserted by a gate that never looked.
3. **The branch's own contrast check measures two nodes** by reading `backgroundColor` directly, a
   method `lib/contrast.js` refuses by design because it steps over `background-image`. It happens to
   land on the right answer for those two nodes. It is not a signoff and it was never going to be one.

**This is the exact failure class the brief named: a check reporting green over something that never
ran.** Three of them, in the gates, on the surface nobody had reviewed.

---

## DOCUMENTED GAPS, RANKED

**Must fix before this panel is seen by the CEO:**

1. Pause and End are off-screen in the ordinary running state, with no scroll cue. (§1)
2. The decision state offers no way to decide, and prints `CEO_DECISION:` and the controller's
   internals as its account. (§2)
3. The headline reports the selected assignment as if it were the portfolio; nothing surfaces "3 need
   you". (§3)
4. `Error: Corrupt committed journal` and "Archive the unreadable plan and preserve its journal" —
   raw error text and a word he does not have, with the destructive option first and the harmless
   Refresh second, and the error printed *below* both. (§ vocabulary)
5. "End run without completing it" is destructive, unconfirmed, and its target can be ambiguous
   because duplicate selector rows are indistinguishable. (§ selector)
6. One noun for the thing. "Run" / "work plan" / "assignment" cannot all survive.
7. `<small>` at 14px on "Completion checks: …" — the definition of done, below the 16px floor for text
   meant to be read, under an exemption that was never declared and would not be honest if it were.

**Should fix:**

8. `["cargo","build","--release"]`, the workspace path and the attempt/timeout mechanics do not belong
   in front of him. If they must exist for an imported plan, they belong behind one disclosure that
   says what it is in his words.
9. "Start / continue" fails the spoken-option rule. So does any label built with a slash.
10. State carried by a word alone, in body weight, in a strip read at a glance. It needs a second
    channel — and per the standing white-label discipline, not color alone either.
11. Selector: lead with the goal, not the state; `text-overflow: ellipsis`; a stable presence rather
    than appearing at n=2; a count; and do not repeat the selected goal verbatim underneath it.
12. "Not finished" for a task that has not started.
13. `[role="status"]` is appended after the buttons, so both visually and to a screen reader the
    actions come before the explanation.
14. Pausing changes nothing visible except a sentence at the bottom of a box he cannot see; the
    headline still says "Working".
15. The panel's height budget is a fixed 240px regardless of window height — 38% of a 680px window.

**Gate work, and it is not optional given what it hid:**

16. Add `runs.js` to `UI_SOURCES` in `lib/state-strings.js`, classify the twelve state labels in
    `lib/state-registry.js`, and let the affordance rule actually run against this panel.
17. Add the Work plan panel to `contrast.js`'s surface list, in at least its empty, running, decision
    and load-failure states, both themes.
18. Replace the two-node `backgroundColor` check in `tests/runs.js` with the shared
    `pageScript()` walk, so this panel is measured by the same arithmetic as everything else.

---

## THE ONE DIRECTION

**Stop building a plan viewer and build a status line with one decision in it.**

The panel today is a nested disclosure tree that renders the controller's data model — goal, tasks,
checks, commands, evidence, and every control at once — inside a 240px box. That is why the stop
button is off-screen, why the decision is three clicks deep, and why twenty assignments and two
assignments look the same.

Invert it. **The panel's resting state is one line: what is happening, and whether he is needed.**
"Working — Q4 investor update, task 2 of 3." Or, when he is needed, that line changes its whole
character and states the choice in his words with the buttons that answer it, on screen, unclipped,
before any of the detail: *"I've spent as long on the Q4 update as you allowed. Keep going, change
what I'm doing, or stop."* Everything else — checks, evidence, commands, workspace, attempts — moves
behind one deliberate "Show me what happened", which he opens when he wants it and which is allowed
to be tall because he asked for it.

The controls that must never be off-screen are Pause and the decision's answers. They pin. The
detail scrolls.

Everything in the ranked list above falls out of that one call, and doing it without that call means
polishing a tree that should not be a tree.

## WHAT I DID NOT CHECK, AND WHY

- **The open `<select>` popup list.** `appearance: none` styles the closed control only; on macOS
  WebKit the open menu is drawn by the platform outside the page, so it has no computed style to read
  and does not appear in a page screenshot. **Its contrast and its behavior with 20 rows are
  unverified by me.** This matters more than usual here, because the popup is the surface he reads
  when choosing, and the app's theme and the OS's appearance can disagree. Someone should look at it
  on a real build, both OS appearances.
- **The panel inside the shipped Tauri binary.** I reviewed it in WebKit via Playwright, which is the
  engine Tauri ships in on macOS and which every UI suite in this repository treats as the target.
  I did not build or run the desktop app. Window chrome, real WKWebView scrollbar behavior and the
  OS accent color are **unverified**.
- **The backend.** I read `run.rs`, `owned_work.rs`, `autonomy.rs` and `STREAMING.md` only far enough
  to render the panel with the strings the controller actually produces. Nothing about the controller's
  correctness is in scope here and nothing about it is claimed.
- **Tab order past the `<select>`.** Repeated Tab presses cycled between the summary and the select and
  never reached the buttons — consistent with macOS WebKit's default of keeping buttons out of the tab
  order unless full keyboard access is on. **That is a shell-wide platform behavior, not a P4 defect,
  and I did not verify it against the rest of the app, so I am not charging it to this panel.**
- **`updates.js`'s absence from `UI_SOURCES`.** Noticed while confirming `runs.js`'s absence. Out of
  scope; flagged for whoever owns that surface.

## FIT TO BE SEEN BY A NON-TECHNICAL CEO?

**No.** Two sentences would decide it on their own: he cannot see the button that stops the work, and
when the system needs his authority it tells him so in a line beginning `CEO_DECISION:` and then gives
him nothing to press.

The contrast floor is clear in both themes and I am happy to say so. It was never the thing that would
have embarrassed him.

---

*Withheld by Urban, Principal Product Designer, 2026-09-05. Re-review on request once the direction
above is implemented — the panel is one good decision away from being fine.*
