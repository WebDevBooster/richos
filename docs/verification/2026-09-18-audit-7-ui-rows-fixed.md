# Audit-7's UI rows, fixed — what each one actually was, measured

Echo (Rust & Tauri desktop engineer), 2026-09-18. Branch `cc/echo-opus-ui1`, worktree
`/Users/alex/ab/richos-wt/echo-opus-ui1`, base `9c03b1d4`.

Ray walked candidate .7 (`v1.2.0-nightly.20260918.1`, source `9da3c7d5`) and refused it
(`docs/verification/2026-09-18-nightly-1.2.0-20260918.1-onscreen-audit.md`). This covers the
rows that are UI: **3, 5, 9, 10, 11, 12, 13**, plus the UI half of **row 2** added mid-task.
Rows 1, 2 (backend) and 4 belong to other teammates. **Row 8 is not a UI defect at all and is
escalated** — §9 below.

**THE RUNNING BINARY'S UI IS THIS TREE'S UI.** `git diff 9da3c7d5..HEAD -- app/ui/` was empty
when this work started, so every reproduction below is against the code Ray walked and not
against something that had already moved.

**No audio anywhere in this work.** Nothing here touches voice, barge-in or interruption, so
the standing limitation on audio testing on this Mac (CEO, 2026-09-18) does not bind any
measurement below. `pgrep -fl richos-tauri` returned nothing at the start of this session and
again at the end: no candidate was on screen, nothing was launched, and pid `98757` and the
`richos-qa-cand7` HOME were never touched.

**Method.** Every reproduction is a real `page.mouse.click` / `page.keyboard.press` under
WebKit — the engine Tauri ships on macOS — against `app/ui/index.html` loaded from disk, with
nothing stubbed but the bridge `mock.js` already replaces. Every fix carries a check that was
watched to go RED with the fix removed and GREEN with it in. Contrast is computed, never
eyeballed.

---

## 1. Row 3, High — the front door did not open. TWO causes, both reproduced.

### 3a — the word `Enter` had no handler

`#home-door-cap` was a bare `<p>` with `cursor: auto` sitting directly under the primary
button. `elementFromPoint` at the middle of it returns `home-door-cap`, so all four of Ray's
clicks across two launches landed exactly where he aimed and nothing was listening. Measured
before the fix:

    click the caption   ->  RichHome.isOpen() still true, activeElement dropped to BODY

The word is part of the door now and leaves with reason `"caption"`. It stays a `<p>` and its
type, size, color and letter-spacing are the owner's 2026-09-02 ruling, untouched; the only
appearance change is `cursor: pointer` and a hit area clamped to the word itself
(`width: max-content`), so a click 300px to its right is not a way in. It gets no `role` and no
tab stop: `#home-enter` already carries `aria-keyshortcuts="Enter"`, and announcing a second
button for one door would describe the screen worse than it describes it now.

### 3b — one click on the settings control killed the key for the rest of the launch

`onHomeKey` refused any keystroke whose target was inside `.settings`. That clause was written
for the OPEN menu, but `settings-button.js` deliberately hands focus back to `#set-btn` when
the menu closes (`close(true)` on Escape). Measured before the fix:

| step | menu | `activeElement` | home screen |
|---|---|---|---|
| click `#set-btn` | open | `BODY` | up |
| Escape | closed | `set-btn` | up |
| **Return** | **open again** | `set-btn` | **still up** |
| **Return** | closed | `set-btn` | **still up** |

So the settings control is the only other control on that screen, it is the first thing anyone
touches, and touching it silently broke the promise the word `Enter` makes. The refusal is now
scoped to the menu actually being on screen. Return from the door and from `<body>` always
worked and still does.

**Ray's "not to Return" is only half-explained by 3b and I say so rather than claim it.** His
table puts both Return attempts BEFORE his settings click, and Return from a clean arrival
reproduces green at every attempt here. 3b is a real, reproducible path that breaks the key for
a person; whether it is the one he hit, I cannot say. The one thing in his own record that
points elsewhere is that his window moved from `(664,108)` to `(438,92)` at `08:05:53Z` — after
`a7-02`/`a7-03`/`a7-04` — and the deleted `a7-03-after-return.png` is described as "a strip of
the same desktop", which is what an early capture against a stale window position looks like.

### The gate that now catches this class

`affordances.js` PART 6, blocking: every element on the opening screen that PRESENTS as a
control — `<button>`, `<a href>`, `[role=button]`, or computed `cursor: pointer` — must be
WIRED for a press. The question is asked by wrapping `addEventListener` before the page's
scripts run, not by clicking and watching observables: the first draft did the latter and
called all seven company chips dead, because a chip changes `aria-pressed` and the
already-selected one correctly changes nothing. Delegation counts; a document- or window-level
handler does not, or `settings-button.js`'s click-outside listener would vouch for the whole
page. Its positive control plants exactly row 3 and a wired twin, and proves the criterion
separates them. A third check walks the door with real input.

**Why nothing caught it before:** `tests/home.js` already had a check named "the word `Enter` is
a promise the key keeps, from anywhere on the screen" and it was green over BOTH defects,
because it drives the screen through `RichHome` and `page.keyboard`; `lib/harness.js`'s
`leaveHome()` calls `RichHome.hide()` directly, so no suite in the directory had ever used the
front door the way a person does.

---

## 2. Row 5, Medium — the sheet opened behind the opening screen

Measured, before the fix:

    #home                computed z-index 150, position fixed
    #repositories-sheet  computed z-index  60, position fixed
    elementFromPoint at the middle of the sheet's own panel  ->  home-overlay

**And it was worse than invisible, which Ray could not have seen.** `repositories.js`'s `open()`
focuses the company select, and `onFocusIn` pulled focus straight back to the door — measured:
sheet open, `activeElement` = `home-enter`. Even painted in front it could not have been typed
into. That is the same defect `#home-prefs` already carries an explicit exception for, in the
note directly above `onFocusIn`; a second surface had the same shape and no exception.

**The screen gives way; the sheet is not raised.** The owner's 2026-09-02 ruling is that nothing
covers the spectacle of this composition, so raising `.overlay` above `#home` would put an
arbitrary modal over it. These sheets live on the desk — the settings menu that opens them
floats above every screen by §15, the sheets do not — so a row that opens one is a way through,
exactly like the door. Giving way settles the focus half in the same move.

Derived, not enumerated: the trigger is "a `.overlay` that is a direct child of `<body>` stopped
being hidden", which is what a desk sheet structurally IS. Three today
(`#repositories-sheet`, `#permission-sheet`, `#quit-question`). `#home-prefs` is body-level too
and deliberately not an `.overlay`; the new check's negative control asserts both facts, so the
rule cannot start catching it by accident.

---

## 3. Row 9, Low — a held result came back at the end of the thread

`assignment::PendingNotice` has always carried `raisedAtMs` and `take_pending_notices` returns
them oldest first. `main.js` read `notice.text` and nothing else, so `richVoiceSays` stamped
`Date.now()` and `addLocalNotice` pushed the card to the end of `turnOrder`. A failure that had
been on disk for six minutes was rendered as "this just happened".

The arithmetic to place it correctly already existed and was reachable from only one of the two
paths: `restoreLocalNotices` (the in-session carry) placed a notice before the first turn that
started after it, and its own comment says why. `addLocalNotice`, the path every notice is BORN
on including the relaunch drain, pushed unconditionally. One shared `placeByTime` now.

Threaded end to end, with the notice's own time held through the turn-boundary queue as well —
a notice waiting for a boundary can wait minutes, and stamping it at the boundary would
misplace it the same way. The live `rich://` lane still means now, so it is byte-for-byte the
behavior it had.

Check: a thread rebuilt from the ledger the way a relaunch does it (two answers, no notices),
then a failure raised BETWEEN them handed over. Required order `Twelve. / notice / Paris.`; one
raised NOW must still come last. Red before the fix with `Twelve. | Paris. | notice`.

---

## 4. Row 10, Low — the first Return did not send

`send()` opened with `if (mainView === "opening") return;`. That view is the window between a
thread being asked for and its timeline arriving — six bridge round trips — and through all of
it the composer is editable and carries the IDLE placeholder `Talk to Rich…`. Send is visible
but DISABLED, so the button refused him honestly; Return refused him silently.

Reproduced with the harness's own slow-bridge lever at 400 ms, which is what a cold first run
costs:

    click a thread   ->  composer mode "opening", placeholder "Talk to Rich…",
                         send visible but disabled, input editable
    type + Return    ->  text still in the box, ZERO user bubbles
    6 s later        ->  mode "idle", text still in the box, nothing sent
    Return again     ->  sent

The refusal itself is right and did not change. What was missing is that `openThread`'s own tail
already declares where a sentence typed in that window belongs —
`drafts.set(threadId, inputEl.value)`, commented "typing while opening belongs to this
destination" — and the same declaration had never been made for the SEND. It is held and
replayed when the thread is on screen.

Three things it refuses to guess, each of which would be worse than the defect: at most ONE
message however many times he presses Return; never a sentence he edited after submitting;
never the wrong thread.

The checks run at 120 ms and 400 ms in `slow-bridge.js`, which is where this class lives — that
file already holds two defects of exactly this shape. Red before the fix at both latencies.

**One obsolete assertion elsewhere, changed deliberately.** `waiting-lifecycle.js` required the
sentence he pressed Return on to still be in the composer after the new conversation arrived —
the defect, encoded as an expectation. It now requires the held send to have landed and the
waiting band to read "Sending your message"; the two facts that check exists for are untouched.

---

## 5. Row 11, Low — his own words at 3.09:1

`opacity: 0.72` on the whole pending bubble. Opacity composites the text AND its background
against the page together, so it takes the ink down with the fill. Computed from the tokens,
both themes, alpha compositing done explicitly:

|  | light | dark |
|---|---|---|
| **opacity 0.72 (shipped)** | **3.09:1 FAIL** | **3.67:1 FAIL** |
| opacity 0.80 | 3.63:1 FAIL | 4.21:1 FAIL |
| opacity 0.85 | 4.02:1 FAIL | 4.58:1 pass |
| opacity 0.90 | 4.47:1 FAIL | 4.96:1 pass |
| opacity 1.00 (settled) | 5.55:1 pass | 5.77:1 pass |

**There is no opacity that both softens the bubble and clears the floor** — even 0.90, barely a
notch, is 4.47:1 in light mode, which is the theme the desk is in. The derivation reproduces
Ray's own screen readings (3.09 and 5.50) to 0.05, which is what makes the rest of the table
worth trusting.

The quiet comes from the FILL alone now: `--bg-user-pending` is the same gold at half the alpha
of `--gold-soft`, per theme, so the bubble reads as not-yet-settled exactly as the transparency
made it read and the ink's contrast goes UP — **6.18:1 dark, 5.71:1 light**. No spinner, no
"sending…" label, no layout change.

**Declared exemption, where a reviewer sees it:** the bubble's FILL against the page is a
decorative highlight and not a non-text indicator — it is `--gold-soft`, whose interior
`style.css` already declares exempt on the same ground at the progress track (1.22:1 dark /
1.13:1 light); the pending fill is 1.09:1 / 1.06:1. Pending-ness was carried by that fill in the
old treatment too, so nothing communicated has been taken away. **His own sentence is not
exempt and never was.**

New `contrast.js` surface `pending-user-bubble` holds the state through the SHIPPING path —
`send_message` is given a promise that never settles — and refuses a walk in which the bubble
settled. 112 of 500 nodes, both themes agreeing. With `opacity: 0.72` put back it goes red
naming the node: 3.17:1 light, 3.8:1 dark. Three independent methods within 0.08 in light mode.

---

## 6. Row 12, Low — the counters went down, and a second defect underneath it

The demonstration's counters climb as the field lands its learning lines and started again from
zero on the next boot: Ray read 7,673 / 4,853 before the relaunch and 7,520 / 4,804 after.

**The second defect is one Ray could not have seen.** The same engine draws his REAL corpus, and
`landed` was added to the total either way — so the animation was incrementing the count of his
own memories, putting a number on his home screen that nothing on his disk supports. That is
worse than the sawtooth and it was shipping.

Fixed as two answers to two datasets: the demonstration remembers its delta (keyed by the
dataset's own name, clamped on read to non-negative finite integers so a foreign value cannot
make the HUD count down), and over a real corpus the animation adds nothing at all — the line
still lands and still flashes its source in the ticker, and moves no total.

Measured: demonstration `7500 -> 7511` while watching, `7511` after the relaunch; his own corpus
`7500` before three landings and `7500` after, with `landed {"sources":0,"memories":0}`. Red
before the fix: `memories went DOWN across the relaunch: 7507 -> 7500`.

---

## 7. Row 13, Carried — the corpus sheet, and the overlapping names

### 13a — "Not now" was forgotten at every launch

`maybeAskAboutMemory` had no record of a decline, so on a machine where `memory_status` is
`none` the question was asked forever. **It is the same defect the branch DIRECTLY BELOW it was
fixed for on 2026-09-04**, whose comment reads: "This branch used to open the dialog at every
launch. On a provisioned machine with no compiler that is EVERY launch forever … a permanent
interruption rather than a one-time notice." The `state === "none"` case three lines above it
had exactly that shape and was never touched.

Only "Not now" records an answer. `Close`, the scrim and Escape dismiss the sheet in its DONE
state, which is a different screen with nothing to decline.

**Going quiet without leaving a way in would trade a nag for a dead end**, and the affordance
rule is right to refuse that — so §15's settings menu carries `Memory folder` beside `Connected
repositories` and `Account connection`, re-reading `memory_status` at the press because
`provision_memory` can be run from this window.

**Said plainly, because it is a real gap: this is the honest fallback and not the right home.**
Every other durable preference here is a Rust `ConfigStore` value with a `localStorage` mirror
in front of it, and this one has no backend field to mirror. Adding one is `richos-core`, which
this brief forbids. So what ships is the mirror alone: it survives a relaunch, which is the
whole of the defect, and it is lost if the webview's storage is cleared, which costs him one
dismissal. **The durable half is a `memory_setup_declined` flag on the config record and it does
not exist yet.**

One new sentence was needed and is declared rather than slipped in: `MemoryStatus` has four
states and only three had copy, because the boot path deliberately says nothing for `unusable`.
A row he presses HIMSELF has to answer, so `MEMORY_UNUSABLE` answers in `MEMORY_NO_READER`'s
register — what is off, what is still on, that nothing is required of him — and names no party,
for the reason `MEMORY_NO_READER` stopped naming one: on a customer's Mac the person who set
RichOS up is him. Both it and the status-read failure line are classified in the state registry
with their reasoning; the affordance gate refused them until they were.

### 13b — `CAPITAL 558` under `LEGAL & RISK`

`clearingShift` tested a label's box against `blockRects` — chrome, re-read from the DOM each
frame — plus the ticker zone and the viewport edges. Two domain names were never tested against
each other. The sweep in `home-fit.js` had the same hole in the same shape.

Reproduced at 1024x700, exactly the pair Ray named, at cursor 380,90:

    CAPITAL      [370.2, 404.7 -> 478.7, 446.7]
    LEGAL & RISK [391.2, 435.5 -> 556.3, 477.5]
    horizontal overlap  87.5px       vertical overlap  11.2px
    189 overlapping samples across the 132-position sweep, every one of them GLYPHS

**The lift is what makes the fix cheap.** `clearingShift` is horizontal-only for a good reason
that does not hold between two names: every chrome rect is a tall column or a wide band, so
against CHROME the axis with room is x. Two names are neither — the pair above needs 87.5px
sideways, past the 64px budget, and 12px of height clears it. The whole sweep, three ways:

| | names/position at 1024x700 | overlapping pairs |
|---|---|---|
| as it shipped | 7.28 | **189** |
| horizontal-only | 5.82 | 0 |
| **lift first, then horizontal** | **6.87 / 6.88** | **0** |

Horizontal-only would have bought the clean screen by fading 1.46 names per position. 1400x880
moves the same way: 11.38 with overlaps, 10.36 clean. (The two figures for the chosen fix are
two separate runs — the picture is live, so the sample count varies by a hair between runs;
both were measured, neither is rounded.)

The lift budget is 22px against a 42px line box, tried only against other NAMES; a lift into the
chrome is refused like any other position. A name that cannot be settled either way still fades,
which is the engine's own rule ("A label is either legible or absent") and never a clipped one.

---

## 8. Row 2, the UI half — added mid-task

`renderDrillChip` counted `["registered", "preparing", "running"]` together and printed
"N assignments running", so a job that had only been written down appeared on his chip as work
under way. `AssignmentState`'s doc comments keep the three apart and `work-summary.js` has
always relayed them apart; the chip was the one surface that flattened them, and it flattened
them to the strongest of the three.

It now reads, for one of each state:

    ⋯ 1 working · 1 done · 2 assignments starting · 1 assignment running · 1 I can't see

The noun stays on both parts because `${active} working` two parts up is about WORKERS. The
accessible name carries the same words, so it means the same read or spoken. The check fails in
both directions and carries a `settled` and an `unknown` row that must not creep into either
count.

**The line numbers in the request were `main.js:2918-2920`; in this tree they were 2980-2982.
The code was exactly as described.**

---

## 9. Row 8 — NOT a UI defect. Escalated.

The brief called this "the UI half — fix the join". **There is no UI half.** The only producer
of that sentence is `richos-core/src/assignment.rs:281`:

    format!("I've taken down your assignment: {}. It's running now, and you'll find it \
             with your saved work. …", self.title)

`self.title` already ends in a period — `sanitize_title` truncates to end in one, and the CEO's
own title ended "…and land it." — so the `.` in the format string is the second period.
`grep -rn 'taken down your assignment|assignment:' app/ui/*.js` returns nothing.

`richos-core` is explicitly outside this brief's footprint and belongs to `echo-opus-pluginbind1`.
Raised as **`esc-20260918T085540Z-a89cf867`**, state `proceeding`. **Row 8 ships unfixed unless
it is routed there.**

---

## 10. What was run

| | result |
|---|---|
| `cargo check` in `src-tauri` | finished, 0 errors, 4 pre-existing warnings (`git diff 9c03b1d4..HEAD -- '*.rs'` is empty — no Rust was touched) |
| `ui/tests` full runner | see the branch's final commit message for the tail |
| `bash richos/app/scripts/gui-boot.test.sh` | **exit 2 on a missing prerequisite, not a failure.** 14 checks passed (S1, A0–A8, C1–C4) and it then stopped with `provide an extracted engine with runtimes via RICHOS_GUI_ENGINE_SOURCE, or a verified RICHOS_RUNTIME_DIR`. It was run because `pgrep -fl richos-tauri` showed no candidate. It exercises the Rust boot log and reaches no `app/ui/` file. |

Nothing was merged, pushed or deployed. `nightly-local.py` was not run. `~/RichOS`,
`~/.richos-signing`, the installed app, pid `98757` and the `richos-qa-cand7` HOME were not
touched.

---

## 11. Candidate .8's four rows, added mid-task — one fixed, three answered

Ray's candidate-.8 walk (`docs/verification/2026-09-18-nightly-1.2.0-20260918.2-onscreen-audit.md`,
source `a7c875d6`) sharpened four rows. **The first thing to establish, because three of the four
turn on it:**

    git diff 9da3c7d5..a7c875d6 -- richos/app/ui/     ->     EMPTY

**The UI is byte-identical between candidate .7 and candidate .8.** Whatever changed between
those two builds, none of it is in the renderer.

### .8 row 3 — `Enter` is `static text`. FIXED, and it is the cause my row 3a measured.

His accessibility transcript is the cause audit-7 could only observe, and it agrees with the
measurement in §1 above exactly: a `<p>`, no role, not focusable. The click half was already
fixed here; the tree half is fixed now — `aria-hidden="true"`, no role, no tab stop, with the
fact the word carries left where the platform looks for it (`aria-keyshortcuts` on the door).

### .8 row 4 — "the Return key never sends". CANNOT BE A UI REGRESSION, and does not reproduce.

He calls it "a regression from 'annoying' to 'the keyboard does not send'", on the basis that
.7's second Return worked and .8's third did not. **The renderer did not change between those
builds**, so a regression in it is impossible. And "never sends" does not reproduce here: on a
settled desk, under real WebKit, one `page.keyboard.press("Enter")` into `#input` sends —
measured before any fix on this branch (zero user bubbles to one, box emptied).

What IS real and is fixed is the narrower thing: a Return pressed while the thread is still
opening was silently dropped (§4 above), which at 400 ms of bridge latency is a window seconds
wide on a cold boot and is exactly "the first Return does not send".

**The common factor in what does not reproduce is his input method, and it is worth naming.**
Across both walks: his synthetic CLICKS always reach the app (every positive control passes),
and his synthetic KEY events — Return on the opening screen (.7 row 3, .8 row 3), Return in the
composer (.8 row 4), Escape on the settings menu (.8 row 11) — reach it inconsistently or not at
all, while the same keystrokes reproduce green here through WebKit's own event path. That is a
harness question, not a renderer one, and it is the same class my own definition warns about for
audio: a defect found with a synthetic stand-in is a harness artifact until a human at the desk
reproduces it. **Recorded, not concluded** — and it is a claim about the instrument, so it is
worth an actual test rather than more argument: one person at the keyboard, three keystrokes.

### .8 row 11 — Escape does not close the settings panel. DOES NOT REPRODUCE.

Measured under WebKit, from the opening screen, both from the control and with focus on a switch
inside the open menu — which is where his hand was, he had just flipped `Opening screen`:

    click #set-btn      ->  menu open
    Escape              ->  menu CLOSED, focus back on set-btn
    reopen, focus #set-techy, click it
    Escape              ->  menu CLOSED, focus back on set-btn

Two independent handlers close it (`settings-button.js`'s own Escape, and `main.js`'s
`dismissTopmostPopup`), and `escape.js` in the acceptance suite refuses any
structurally-a-popup element that carries no dismissal declaration. Nothing to fix in source
from this evidence.

### .8 row 5 — turning the opening screen off is ignored. FIXED, after the escalation was answered.

**This section is left as it was written, because the answer changed the diagnosis and the
change is the useful part.** It closed on "a missing cache is the only remaining mechanism",
raised the question, and the answer came back: **the store persists, and it is keyed by BUNDLE
ID rather than by `$HOME`.** Verified independently here —
`~/Library/WebKit/com.richos.app/WebsiteData/…/LocalStorage/localstorage.sqlite3`, written at
11:39–11:45 today, during both walks; and `~/Library/WebKit/` still holds
`com.richos.app.RAY-101-RUN-A`, `-B` and `-C` from earlier walks that isolated deliberately.

So the cache was never missing. **It is SHARED between installs that disagree.** A candidate
walked under a QA scratch `HOME` reads a different `config.json` from the CEO's installed app and
writes into the same `localStorage`, and `syncSplashFromBackend` writes each instance's own
durable answer into that one mirror at the end of every boot. Last writer wins, and the loser
draws a curtain its owner switched off. That is a better mechanism than the one below and it
fits the evidence exactly — including why it came back **twice**.

The fix is the one the section below names: the durable answer travels in the Tauri
initialization script that already carries the launch kind, and `splash.js` prefers it. The
mirror stays for the settings row and for a page with no Tauri behind it. Checked four ways with
the mirror and the durable answer deliberately disagreeing, and proven able to fail.

**What the record should carry beyond this row:** the splash mirror — and every other
`localStorage` value this app keeps — is shared across every instance with the same bundle id,
whatever `HOME` it was launched under. That is a property of the platform, not of this app, and
it makes a scratch-`HOME` walk a walk that can move the CEO's own settings.

The original diagnosis follows, unedited.

### .8 row 5 — the trace that led there

Traced end to end, and every step but the last one is sound:

  * `set_splash_enabled` persists — his `config.json` proves it (`"splash_enabled": false`,
    `splash_disabled_at` stamped);
  * `splash_enabled` returns a bare `bool`, so `syncSplashFromBackend`'s
    `(await invoke) !== false` cannot poison the mirror;
  * `setSplashEnabled` writes the `localStorage` mirror synchronously at the press;
  * `splash.js`'s `enabled()` reads **only** that mirror, at parse time in the head;
  * `main.js` reconciles the mirror from the backend at the very END of `init()`, under a
    comment that says so outright: *"neither call affects anything the CEO can see this launch"*.

**So the curtain's first-paint decision is taken from a CACHE, and the durable answer is never
consulted before it is taken.** On any launch where that cache is absent, the CEO's "off" is
ignored — and given the four sound steps above, a missing cache is the only remaining mechanism
for it coming back on the next two launches.

The honest fix is for the durable answer to be in the document before any script runs — a
`src-tauri` initialization script — because the alternatives inside `ui/` are a delayed first
paint (§5.5 forbids it) or drawing the curtain and yanking it away (worse than the defect).
**That was outside this brief's original footprint, so it was escalated rather than faked:**
`esc-20260918T111438Z-8f6a1a75`. The lead answered it and directed the hunk; it is landed.

### AND IT PUT A QUESTION UNDER TWO OF MY OWN FIXES — asked, and answered: they are fine

Rows 12 and 13a both persist in `localStorage`, and both pass every test. If the installed
webview's storage did not survive a relaunch, both would have been inert on the installed app
while green here — so it was raised before it could land quietly rather than after somebody
found it. **The answer is that the store does persist**, so both fixes hold on the installed
app. The same answer carried the sharper fact above, which is why asking was worth more than
assuming either way.
