# The window closes and the work keeps going; a crash invents nothing — what was measured

**Date:** 2026-09-17. **Branch:** `cc/echo-opus-resident1`. **Base:** richos main `eef1580b`,
with main `6796cdf2` merged mid-slice (the candidate-5 voice fix; acknowledged durably with
`inflight-ack.sh`, impact `none`).

**What governs this, in order.** The CEO's **Two Riches spec** — his words, verbatim — which
lives in the private richos-hq record and **is not in this repository**; rows 5 and 9 of his
nine are what this slice makes true. The **background-work spec** — revision 5, named for the same date and held in the
private richos-hq record beside the page, **not in this repository** — is the engineering
annex:
§2.3–§2.5a, §2.9, §6.1–§6.3a and the acceptance steps §7.4, §7.4a, §7.7. Everything asserted
below about the CODE carries its own `file:line` in this repository, so none of it depends on
having those documents to hand.

**A correction to the brief's own paths, first, because a reader will otherwise look in the
wrong place.** The brief points at a verification directory under `richos/` and at a plans
directory for the annex. In this repository the verification records live at
`docs/verification/` (repository root), and neither the CEO's page nor its annex is in this
repository at all — both are in the private richos-hq record. Nothing followed from that
beyond where this file sits.

---

## 1. What was walked on this Mac, and what was not

### 1.1 §7.7 WAS walked, on the real app binary, with a real kill

The app was built (`cargo build` in `src-tauri`, debug) and booted under a temp `HOME` with
**no** activation override, so the launch decides `Accessory`: no Dock icon, and a window
built invisible and never ordered on screen (`activation.rs:1-18, 304-314`, whose measured
ablation is in the file). **No screen was woken, nothing was unlocked, and no focus was
taken** — the app said so itself on every boot:

```
[richos] activation: accessory — no Dock icon, no window on screen, no focus taken,
because this is not an installed launch: …/target/debug/richos-tauri is not inside a .app
bundle; a program is holding this process (parent pid 3190)…
```

**Boot 1** — a receipt seeded in `state: running` (what a crash leaves behind: the last thing
written was that it was running) plus an orphan work grant left `actions_allowed: true`:

```
[richos] launch: fresh (start 1, 1 window(s))
[richos] recovery: this launch has no verified Git runtime, so an assignment's repository is
         recorded as unread rather than as unchanged.
[richos] recovery: 1 assignment(s) unknown until re-witnessed, 0 left as recorded;
         1 orphan grant(s) closed
```

The receipt on disk afterwards, read back rather than assumed:

```
state   : unknown
detail  : It was running when RichOS closed. Nothing has looked since, so nothing is being
          called finished.
notice  : unknown | landing the three branches was running when RichOS closed, and I can't
          tell you how it ended. I couldn't read your repository to check. I couldn't read
          its work records. Nothing is running now and nothing was finished. Say the word
          and I'll pick it back up. | delivered: None
grant   : actions_allowed = False
```

Then `kill -9` — a real crash, no clean exit, no destructors, no `RunEvent::Exit`.

**Boot 2**, on the relaunch, which the app independently classifies as a crash-restart from
its own clean-exit marker:

```
[richos] launch: crash-restart (start -, 1 window(s))
[richos] recovery: 0 assignment(s) unknown until re-witnessed, 0 left as recorded
```

Zero, and that is the point: `unknown` is not open, so nothing sweeps it up again, nothing
restarts it, and he is not told the same thing twice. The only exit from `unknown` is him.

**Boot 3**, with the same receipt seeded `blocked` instead — §7.8's case surviving a relaunch:

```
[richos] recovery: 0 assignment(s) unknown until re-witnessed, 1 left as recorded
state after boot3: blocked | notices: 0
```

Left exactly as it stood, and nothing said about it: he was already told, and telling him
again about the same waiting decision is noise pretending to be diligence.

**What this boot could NOT establish, said rather than implied.** This launch has no verified
engine runtime — the runtime's delivery manifest is a delivered artifact and is not in a
source checkout — so the Git half of §6.1
took its honest branch — *"I couldn't read your repository to check"* — instead of comparing
a pin. The comparison itself is covered by unit tests in both directions (unmoved, moved,
unreadable) and by a real-repository roundtrip of the reader
(`recovery.rs`'s `the_git_reading_is_a_commit_id_or_an_honest_nothing`).

### 1.2 §7.4 and §7.4a were NOT walked, and the reason is a fact about this Mac

**Another agent's on-screen audit holds the screen.** Checked before running anything, as the
brief requires, and again at the end of the slice:

```
$ pgrep -fl richos-tauri
42051 ./RichOS.app/Contents/MacOS/richos-tauri
$ ps -o ppid=,lstart= -p 42051        ->  ppid 1, Thu 17 Sep 22:38:06 2026
$ lsof -a -p 42051 -d cwd             ->  …/scratchpad/richos-qa-cand6
$ osascript -e 'tell application "System Events" to return name of first process whose
  frontmost is true'                  ->  richos-tauri
```

That is the candidate-6 QA walk, launched by `launchd` from its own bundle and **frontmost**.
Walking §7.4 needs the opposite of an accessory boot: §2.4b states the precondition — a
double-clicked installed bundle, or `RICHOS_ACTIVATION=regular` — and that branch takes the
screen by construction (`.visible(true)`, `set_focus()` → `activateIgnoringOtherApps`,
`main.rs`'s window block). Launching it then would have interrupted someone else's audit
mid-walk.

**Checked again at the end of the slice, and the answer changed to a second reason that is
stronger than the first.** The candidate-6 walk had finished — `pgrep -fl richos-tauri`
returned nothing — and **a person is at this Mac right now**:

```
$ osascript … frontmost is true      ->  Google Chrome
$ ioreg -c IOHIDSystem | HIDIdleTime ->  1 s, then 3 s, then 5 s over three samples
```

An idle time of one second climbing with the clock is the last human input having happened a
second before the first sample. `activateIgnoringOtherApps` is precisely the call the CEO
felt on 2026-09-06 — *"it takes the keyboard out of the window he is typing in, from a
process he did not start"* — and `main.rs`'s own window block says so at the line that makes
it. A walk that takes his keyboard while he is using it is not a walk worth having, so this
one did not run.

**A second precondition, independent of the first, and it does not go away when the screen
frees up.** §7.4's second half is *"he clicks the Dock icon and the window comes back"*, and
§7.4a's is *"choose Quit; the choice appears"*. Both are clicks on macOS chrome rather than
on the app's own surface — the Dock tile and the menu bar — and driving either needs System
Events with accessibility permission granted to whatever drives it. This session can run
`osascript` for a read (above), and that is not the same permission as posting a click.

**So what is unobserved is precise:** the window staying closed while the work runs, the Dock
icon bringing it back, the quit question appearing on a real Cmd-Q, and the app closing itself
when the last assignment settles with no window open. Every one of them has an in-process
measurement below, and **none of those measurements is a claim that the walk will pass.**

**`gui-boot.test.sh` was not run, and would have refused on its own precondition:** the
engine runtime's delivery manifest — a delivered artifact, never committed — is not in this
worktree, which is the declared host gap it exits 2 on. That is the same refusal the previous two slices recorded.

---

## 2. What WAS measured

### 2.1 The exit decision, five branches, in a file with no Tauri in it

`src-tauri/src/lifecycle.rs`, driven by `cargo test --bin richos-tauri` (118 passed, 5 of
them new):

| Situation | Decision | Why |
|---|---|---|
| He confirmed the quit | Allow | the second pass through the same arm; without it the two-step prevent is a trap |
| Nothing registered, window closed | **Allow** | §2.4's *"idle must still quit"*, exactly today's behavior |
| Work registered, window closed, Dock icon exists | **StayResident** | the CEO's decision |
| Work registered, quit | **AskBeforeQuitting** | §2.5, and the prevent comes first |
| Work registered, no way back in (`Accessory`) | Allow | a process he can neither see nor reach is what §2.4a refuses |

An **unreadable register counts as work**, never as zero — the same rule `app_workers.rs:33-47`
keeps — and the question then says what it does not know rather than naming a count it has not
got.

### 2.2 The rotation, and the numbers it runs on

`work_host.rs`. Sage's finding 11 re-derived at `eef1580b` before building on it: its own grep
(`context_chars|usage_update|watermark|rotate` against that file) still returned **no
matches**, so the gap was real and unchanged.

The watermark is the conversation spine's, made `pub(crate)` and re-used rather than re-chosen
— `DEFAULT_CONTEXT_WINDOW_TOKENS` 200_000, `DEFAULT_WATERMARK_RATIO` 0.70,
`CHARS_PER_TOKEN_ESTIMATE` 4 (`spine.rs:143-158`). Measured first, estimated only as a
fallback, because that estimate was measured wrong by 2.3× to 40.6×.

Walked in `the_back_end_renews_itself_at_a_boundary_and_an_open_assignment_survives_it`:
a back end reporting `used 800_000 / size 1_000_000` (0.80 ≥ 0.70) is renewed at the boundary
**after** its assignment, never inside it; the successor is a visibly different session
(`work-session-rotated-1`); the assignment left `blocked` across the rotation is approved by
him afterwards and comes back on the NEW back end **with the same seat**
(`work-seat:obligation-7`) and a fresh grant, and settles there. The priming payload contains
his own words for what is open and the outgoing back end's five sentences, and contains no
assignment id and no seat — asserted.

### 2.3 Contrast, computed under the real renderer, both themes

`node ui/tests/quit-question.js`, off WebKit's own resolved colors, composited where the
palette uses alpha:

| What | Dark | Light | Floor |
|---|---|---|---|
| "Quit while work is running?" (17px) | **5.78:1** | **6.38:1** | 4.5:1 |
| the question itself (16px) | **5.78:1** | **6.38:1** | 4.5:1 |
| "Keep working" (16px) | **5.78:1** | **6.38:1** | 4.5:1 |
| "Quit and stop the work" (16px) | **7.68:1** | **4.72:1** | 4.5:1 |

Every node is at or above 16px, `ceo-decisions.md` §15's floor for text meant to be easily
read. **Nothing on this sheet is declared exempt**: a question he is being asked is the
definition of text meant to be read.

### 2.4 The wording, read off the rendered DOM

The question never claims the work is finished or that quitting throws it away. The scan is on
PHRASES rather than words, deliberately — *"everything it has done so far is kept"* contains
the word "done" and is the sentence that makes quitting safe to understand, so a bare
substring scan would have failed the very wording it exists to protect — and it carries its
own positive control, a sentence that DOES make the claim and does fire.

The safe answer is focused, and **Escape answers rather than dismisses**: the exit is already
prevented by the time the sheet renders, so a sheet closed without an answer would leave him
pressing Quit against an app that will not go away and says nothing about why.

### 2.5 The suites

- `cargo test -p richos-core`: **661** lib tests and every integration suite green, 0 failed
  (13 of them new in this slice: 2 on the record, 8 in `recovery`, 3 in `work_host`).
- `cargo check` in `src-tauri`: clean (4 pre-existing dead-code warnings, none new).
- `cargo test --bin richos-tauri`: **118** passed, 0 failed.
- `node ui/tests/run.js` — **the whole browser runner: 49 planned, 49 ran, 0 skipped, 694
  checks, all 49 suites passed.** The new `quit-question.js` is one of them (5/5).
- **Three gates refused this work before they passed it, which is the gates working.** The
  affordance gate refused a shipped file with no role in `lib/ui-sources.js`, then four
  unclassified states. The whole-app contrast gate refused a declared panel no driver opens,
  then a floor that could not bite. The documentation gate refused a `rich://` event with no
  entry in `STREAMING.md`, a stale crate total and a suite missing from the suite table.
  Every one is now satisfied rather than waived.

---

## 3. Four things found while building that the spec or the brief does not say

**1. The engine's `reconcile_seats` cannot be called by this app, so §6.3a's seat half is
host-side.** The brief says *"the engine's `reconcile_seats` exists; the app calls it at
boot"*. The function exists (`richos/engine/mega-lander/app.py:946`) and the app cannot reach
it: it runs inside the work adapter's `inspect` tool and **only from an unseated scope** —
`if offset == 0 and scope.get("seat") is None` (`app.py:1069-1072`). Since the CEO's page took
`richos_work` away from the front desk, the only lease holding that tool is the back end
(`native.rs:997`), and a back end's scope is seated the moment it can use a work tool at all.
So the app uses the pair the engine exposes for exactly this — the HOST_ONLY `seats` and
`release-seat` commands (`ecs/adapters/app.py:39, 213, 225`), whose own comment says this
reconciliation is *"the HOST's … never a background lease's"*.

**2. §2.5's premise about the menu is half wrong, and the conclusion survives one level
down.** §2.5 says the app *"builds no menu … so it inherits AppKit's"*. It builds no menu —
true — but Tauri installs `Menu::default` for it (`tauri-2.11.5/src/app.rs:2244-2249`;
`enable_macos_default_menu` defaults true at `:1620`). The Quit in that default is
`PredefinedMenuItem::quit` (`menu/menu.rs:194`), which muda maps to `sel!(terminate:)`
(`muda-0.19.3/src/platform_impl/macos/mod.rs:994`) — still unpreventable, so the app still has
to own that item. **The consequence the spec does not mention:** setting a menu REPLACES the
default entirely, so every other item has to be rebuilt or the webview loses Cmd-C and Cmd-V.

**3. A relaunch could not have resumed anything, because the work lease's session id lived
only in memory.** §6.1 reconciles against the evidence file, which is keyed by session
(`app_workers.rs:38`), and until this slice that id was `Inner::lease_session` and nothing
else. The receipt now carries it (`assignment::note_start`), written on the work lease after
his turn has ended. Without that field, *"reconciled against the evidence file"* was a
sentence with no path behind it.

**4. `unknown` had to be a state, and it had to be a non-open one.** §6.2 says outright that
this is *"a receipt state, not a status"*. Making it open would have meant the update gate
reads busy for ever over work that stopped days ago — §6.5's named trap — so it is
`awaits_his_word()` instead, which is a thing he can act on rather than a thing that blocks
him. It is not `interrupted` either: that state carries the claim that the app SAW the work
stop, and a crash is precisely the case where the process that would have witnessed the
ending is the process that died.

---

## 4. What is deliberately not built

- **The on-screen walk of §7.4, §7.4a and §2.4a's self-quit.** §1.2 above, with both
  preconditions named. The code is there and tested in process; the screen is not this
  slice's to take.
- **Sleep and wake** (§2.6). Still `unverified`, still no sleep handling anywhere in the app,
  and this slice adds none. A connection that is dead while the process believes it is alive
  produces exactly the "started, never ended" receipt recovery now reports as `unknown`, which
  is the honest outcome either way but is not a measurement.
- **Two running instances** (§2.10). Out of scope there and out of scope here. The boot sweep
  closes every `*-work.json` grant it finds, which is right for one instance and would be
  wrong for two; nothing here makes that case better or worse.
- **Carrying a permission REQUEST across a relaunch.** The queue still lives in the running
  process (`permissions.rs`). What survives is the assignment recorded as `blocked`, and his
  approval after a relaunch now reaches it, because the boot sweep hands the host each
  thread's ledger binding. The request itself is gone and the surface says so.
- **§6.5's three-option update offer.** Unchanged from the previous slice: the gate
  distinguishes running from waiting-for-him and says which, and the OFFER is still a surface
  change nobody has made.
- **`Event::PromptReceived` provenance** (`ledger.rs:332-353`), raised by the voice engineer
  mid-slice. Not taken: the field only means anything once the capture path writes it from
  `CapMsg::Started { tainted }`, and that writer is `richos-voice`, another agent's live
  footprint. An always-`None` field would read as "never echo-born", which is worse than the
  gap. It is a follow-up, named here so it is not lost.

## 5. Escalations raised

| Id | State | What it was |
|---|---|---|
| `esc-20260917T214008Z-28032960` | `work-complete` | The build is done and two acceptance steps cannot be walked on this Mac while another agent's audit holds the screen; the Dock-icon and menu-bar clicks need a seat with accessibility permission, or a bundled app and a free screen. |

---

## 6. APPENDED 2026-09-18 — the one open item of the Two Riches spec is closed, the other way

**CEO ruling §52, verbatim:** *"There's nothing that ever not lands on its own here in the
terminal. Anything including things like design mockups always land before they are presented
to me for review. So, yes, always land on its own."*

**What that overrules in this record and in its three siblings.** Everything above about the
window, the process model and crash recovery stands unchanged and was not touched. What does
not stand is the one sentence all four records share about how a job ENDS: that an assignment
whose workers have ended while its obligation is open has run to the step that would change his
repository, stopped there, and is *"ready for you to approve"*. That was a true reading of the
code as it was, and the reason it was true was narrow — `mcp__richos_work__integrate` was the
one work tool not on the permission desk's allow-list, so the job had nowhere to go but his
queue. §52 grants it, on the background audience alone.

**So the sentences in §0 row 7, §5.4 and §7.8 of the annex, and every place in these four
records that quotes them, describe a state this build can no longer be in.** They are left
as written rather than edited: they are what was measured on 2026-09-17, and the record of a
measurement is not improved by being made to agree with a later decision.

**What replaced it, with the evidence in this repository:**

| Ending | State | Where |
|---|---|---|
| obligation closed | `settled`, and the sentence names what landed | `work_host.rs`'s `settle`, `Outcome::Settled` |
| obligation open, a request of his on the desk | `blocked`, still his, Approve/Decline beside it | same, `Outcome::NotSettled if self.pending_decision(…).is_some()` |
| obligation open, nothing waiting for him | `failed` — a job that did not finish, with the reason | same, `Outcome::NotSettled` |
| obligation unreadable | `running`, never any of the above | `outcome()` |

The settle READING is unchanged and is still the obligation alone
(`richos/engine/mega-lander/app.py:664-669`). What he hears for a finished job is the outcome —
the branch, the repository by its own folder name, and whether an independent review passed it
— read off the land record the engine writes onto the work receipt
(`work_status::trail`, from `app.py:809-836` and `:81`), never inferred from the obligation
having closed, and never reported as "nothing landed" when the record simply could not be read.

**Two sentences that were true here and became false were removed rather than kept.** Both
promised his repository was untouched while a job waited on him — `says::ready_to_approve` and
`waiting_on`'s no-request arm. A job that lands on its own may reach a step of his AFTER
landing something, so either would have told him his branch had not moved when it had.

**And the queue this slice's sibling built is not vestigial.** It exists for a request the desk
would have put in front of him in a visible turn and cannot, because there is no turn — a
command on his Mac, a write outside the workspace. That was always its purpose; a land was only
ever held there because the tool that performs it had no grant.

Branch: `cc/echo-opus-land1`. The full reasoning, the mutation checks and the test repairs are
in that branch's commit messages.
