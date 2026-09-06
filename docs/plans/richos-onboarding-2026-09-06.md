# Onboarding an unaccompanied CEO — what has to happen

**Date:** 2026-09-06
**Author:** Urban (principal product designer)
**Occasion:** the first person outside this project to use RichOS reported that
the app never asked him any onboarding questions.
**Scope:** a proposal. No application code was written this round.

---

## What this document had to be re-scoped away from

The brief I was given said there is no onboarding in the product and asked me
to design the questions. **That premise was wrong and was corrected before I
wrote anything**, so nothing below is salvage from it. The interview exists, it
is good, and it does not need a designer.

I re-derived both halves of the correction rather than accepting them:

| Claim | Command | Result |
|---|---|---|
| The app has never heard of the interview | `grep -rn "bootstrap-interview" app/ \| wc -l` | **0** |
| The only executable reference is an advisory string | `grep -rn "bootstrap-interview" engine/scripts/` | 3 hits: `provision-claude-md.sh:159` (a string), `cold-open.test.sh:344` (asserts the doc exists), `publication-completeness.py:280` (a comment) |
| Nothing runs the provisioner | `grep -rn "provision-claude-md\.sh" engine/ --include="*.sh" --include="*.py"` minus its own file and its own test | **no callers** |

All three hold at `d0a08dc`.

## Verification basis — read this before trusting anything below

**This is a source and document audit. I did not run the app.** I have no
signed build, no first-run machine, and no way to stand up a virgin Mac in this
worktree, so every claim here is derived from source at `d0a08dc` and is
labeled with the command that produced it. Where a claim depends on runtime
behavior I could not execute, it says so and names the experiment that would
settle it.

That distinction is load-bearing for one specific claim, flagged again in
context below: **whether the app's inner Claude Code process loads a
`CLAUDE.md` at all.** I could not settle it from source. Everything else here
is a fact about files on disk.

This document is therefore a proposal and a set of findings. **It is not a UX
signoff**, and it must not be read as one. A signoff requires live visual
verification on the real target surface under the rules I hold myself to, and
none was performed.

---

## The finding, in one paragraph

**The trigger for the bootstrap interview exists, and it is written in a file
that is never created.** `engine/CLAUDE.md.template:25` tells the orchestrator
to run the interview *before anything else*. That template becomes a real
`CLAUDE.md` only by way of `scripts/provision-claude-md.sh`, which nothing
invokes — not the app, not the engine installer, not a hook, not another
script. It runs only when a human types it, which is exactly what
`ONBOARDING-RUNBOOK.md` Step 4 tells an operator to do. So the instruction to
interview the CEO is real, correct, well-written, and addressed to a reader who
never receives it. The first outside user got nothing because nobody was
sitting next to him to type one command.

This is worse than a missing feature and better than one. Worse, because the
product ships enforcement and doctrine that silently do not apply. Better,
because the expensive part — the interview itself — is already built.

---

## 1. The chain of breakage

Six links. Each one is independently true, each carries its command, and the
chain breaks at link 3.

| # | Link | State | Evidence |
|---|---|---|---|
| 1 | The interview content exists and is complete | **works** | `engine/skills/bootstrap-interview/SKILL.md`, 437 lines: Stage 0 detection, 6 interview stages, generation phase G1–G5, resumability, transcript mode, honesty rules |
| 2 | A trigger sentence exists telling the orchestrator to run it | **works** | `engine/CLAUDE.md.template:25` — *"Run `skills/bootstrap-interview/SKILL.md` before anything else"*; reinforced at `:37` as one of the three reserved exceptions |
| 3 | The template becomes a real `CLAUDE.md` | **BROKEN** | `ls engine/CLAUDE.md` → no such file. It is gitignored by design (root `.gitignore:5-15`). `provision-claude-md.sh` renders it, and has **no callers** |
| 4 | The provisioner has the two values it refuses to run without | **BROKEN** | It reads `engine/identity.config` for `COMPANY_NAME` and `CEO_NAME`; only `identity.config.example` ships (`git ls-files engine/ \| grep identity`). Blank is an error, not a TODO — `provision-claude-md.sh:107` |
| 5 | The app's inner Rich reads that `CLAUDE.md` | **UNVERIFIED — see §5** | The codebase asserts it would (`reprime.rs:313-316`). I did not execute it |
| 6 | That Rich can carry out the interview's generation phase | **PARTLY BROKEN** | G3 spawns Dean. See §4 |

The app installs Claude Code and the engine and stops. `install_engine`
verifies exactly two things about what it unpacked — `scripts/hooks/` is a
directory and `VERSION` is a file (`setup.rs:1052-1056`). A shipped engine is
"valid" with no `CLAUDE.md`, and that is the state every customer is in.

---

## 2. Where the trigger belongs

**The app's first run — as the fourth step of the chain that already exists
there.** Not the engine's session start.

This is not a new mechanism. The app already runs a first-run chain of exactly
this shape, one dialog at a time, with explicit handoffs between them:

```
main.js:5365   setup sheet   -> installs Claude Code and the engine
main.js:3531   memory        -> "where should your memory live?"  (~/RichOS/corpus)
main.js:5378   company       -> which company this copy works for  (entity picker)
               [ the interview belongs HERE ]
               home screen
```

The ordering comment already in `main.js:5365` states the principle the fourth
step inherits: *"without a `claude` binary and an engine directory there is
nothing for a corpus to be read by and nothing for a company to be chosen
for."* The interview needs all three of those, so it goes last. It cannot be
interleaved with the setup sheet, because the interview is conducted **by** the
thing the setup sheet installs.

**Why not the engine's session start.** Three reasons, in order of weight.

1. **The customer never has a session start.** He double-clicks an app. A
   session start is an event in a terminal he does not open, and designing the
   trigger there is designing for the operator again — which is how we got
   here.
2. **The app owns the only screen.** The interview's first job is to be
   *offered*, visibly, with a real control. An engine-side trigger can only
   produce text in a chat the CEO may not read as an invitation.
3. **The engine cannot know it is being run for a person.** The same engine
   directory serves managed workers and inspector sessions. A session-start
   trigger would have to distinguish those, and the app already knows.

**Why not simply call `provision-claude-md.sh` during setup and stop there.**
Because it would fix link 3 and leave the product asking the CEO for
`COMPANY_NAME` and `CEO_NAME` as config values — which is link 4, and which is
a form. The point of the interview is that those facts arrive in a
conversation. Provisioning must happen, but it is a consequence of the
interview, not a substitute for it (§5, M2).

**What the fourth step actually is.** Not a fifth dialog full of questions. One
sheet, one paragraph, two controls, matching the three that precede it:

> **Rich doesn't know your business yet.**
> Rich can spend about twenty minutes asking about it — what you do, who it's
> for, and how you want to work. Rich writes the answers down and uses them
> from then on. You can stop partway and pick it up later.
>
> `[ Start ]`   `[ Not now ]`

Then it hands off to the chat, and the interview happens in the conversation
where it belongs — because the interview is a conversation, and a wizard would
be the wrong shape for it. The sheet exists only to make the offer *visible*.

---

## 3. What the app must know to decide it has not happened yet

**Positive signal only. Every check below is a fact about a file on disk that
exists because a question was answered.** A launch counter, a "seen it" flag,
or a first-run boolean would all record that the app *showed* something, not
that the CEO *answered* anything — and the failure mode we are fixing is
precisely a product that reported success over work that never happened.

Stage 0 of the skill already specifies its own detection, and it is the right
detection. The question is whether it is reachable from the app. **It is** —
all five signals are files under the engine directory, which is the app's
inner working directory (`engine.rs` header: *"RichOS starts `claude` with the
engine directory as its working directory"*), and the shipped engine really
does carry the literals Stage 0 greps for. Verified:

| Stage 0 signal | Reachable from the app? | Verified |
|---|---|---|
| `grep -c '<!-- TODO (adopter)' CLAUDE.md` | Yes — but on a fresh install there is no `CLAUDE.md` to grep. **Absence is the signal** | `ls engine/CLAUDE.md` → absent |
| `grep -n 'PROTECTED_PATHS="app packages"' orchestration.config` | Yes | present at `engine/orchestration.config:39` — the literal shipped sample |
| `ls .claude/agents/*.md` minus the four meta-roles | Yes | exactly four ship: `clark`, `dean`, `frank`, `reed` |
| `.claude/state/bootstrap-interview-progress.md` | Yes | machine-local, gitignored, absent on a fresh install |
| `grep -rl "BOOTSTRAP-INTERVIEW-TRANSCRIPT" ceo-inbox/` | Yes | `engine/ceo-inbox/` ships with `for-wiki/` and `general/` |

**So the app does not need to invent a check.** It needs one command that runs
Stage 0's checks and returns the four outcomes the skill already defines
(fresh / transcript found / partial / fully bootstrapped). The strongest single
signal — and the one I would build the gate on — is the **absence of
`engine/CLAUDE.md`**, because it is unambiguous, it is what actually breaks the
product, and it cannot be faked by a flag.

One caution, stated because it will otherwise be discovered later: `CLAUDE.md`
is an adopter-owned file that a CEO may edit. The check must be "does a
provisioned `CLAUDE.md` exist and does it still carry unfilled TODO blocks",
never "does it byte-match the template". `provision-claude-md.sh --check`
already exists and already answers a version of this, and it never overwrites a
`CLAUDE.md` the CEO has edited.

---

## 4. What changes when nobody is sitting beside him

The runbook is written for an operator, and it is honest about that on line 1.
Its "Common stalls" section is a list of things a technical person unsticks.
Alone, some of those stalls stop being stalls and become **dead ends** — the
CEO has no way to know what happened, no way to act, and no reason to think the
product is anything other than broken.

Sorting them by what the CEO can actually do:

| Stall | Alone, it is | Why |
|---|---|---|
| **Missing `python3`** | **Dead end** | Every hook fails closed with `ERROR: ... python3 is required`. That text appears in a terminal the CEO does not have open. He sees nothing. This is named as *"the single most common stall"* |
| **Windows** | **Dead end, and it is the correct one** | *"there is no native-Windows execution path today."* This must be refused at download, not discovered at first run |
| **Claude Code not authenticated** | Recoverable | The app already handles it: `SETUP_ACCOUNT_NOTE` says so before the button, and `LEASE_UNAVAILABLE_MESSAGE` covers the after-state |
| **Probe fails Layer I / J** | **Dead end, and silent** | Layer I's own symptom text: *"the orchestrator will see/spawn ZERO teammates at the NEXT session start, with NO error shown"* |
| **Probe fails Layer M (double-fire)** | Recoverable if automated | The fix is running `install.sh`, which the app can do |
| **Probe fails Layer N (git-tracked)** | Not applicable | It concerns committing an adoption. A CEO who never opens a terminal has no repository to commit to |

Three things change about the interview itself.

**First, verification stops being something he is shown.** G5 tells the
orchestrator to run three scripts and *"show the CEO the real output, not a
paraphrase."* Seventeen probe layers and a 7-beat demo scrolling past is a
moment an operator narrates. Alone, it is a wall of green checkmarks that means
nothing to him, and — worse — a wall of red ones he cannot act on. **Alone, the
app must run the verification and say one sentence about the result**, in the
register the setup sheet already uses. The full output stays available for
whoever set RichOS up; it is not the CEO's screen.

**Second, "not sure yet" needs to be visibly safe.** The skill is emphatic that
deferral is honest and TODO blocks are correct. The runbook tells the operator
to *remind* the CEO of that. Alone, nobody reminds him, and an unanswered
question reads as a failure to answer. Rich has to say it, in the first minute,
unprompted.

**Third, and this is the one that matters most: G3 cannot run.** Stage 4
confirms which roles the CEO wants; G3 spawns Dean to instantiate them. **The
app's chat session almost certainly cannot spawn any teammate at all**, because
`child_args` passes `--setting-sources ""` (`native.rs:332-333`) — the stated
reason being that RichOS must not depend on files it did not write. That
excludes the engine's `.claude/settings.local.json`, which is the sole source
of `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"`. Layer I exists to catch exactly
this, and its symptom is zero teammates with no error shown.

So the interview would run, the CEO would answer Stage 4 carefully, and the
staffing step would silently do nothing. **That is the single worst outcome
available here** — worse than today's nothing, because today's nothing at least
does not lie to him. Nothing ships until this is settled.

(A `cargo run` launched from a terminal that exported the variable would
behave differently. The double-clicked `.app` is the case that matters.)

---

## 5. Genuinely missing versus merely unwired

This is the distinction the document exists to draw, so it is drawn plainly.

### Merely unwired — built, tested, and reachable, with no caller

| | What | Evidence |
|---|---|---|
| **U1** | The interview itself | `SKILL.md`, 437 lines, complete. Needs no design work |
| **U2** | The operator runbook | `ONBOARDING-RUNBOOK.md`, 391 lines, complete |
| **U3** | `CLAUDE.md` provisioning | `provision-claude-md.sh` works and has its own test suite. It needs a caller and an `identity.config` |
| **U4** | Stage 0's detection | All five signals present and greppable from the app's working directory (§3) |
| **U5** | The trigger sentence | `CLAUDE.md.template:25`. Correct, and in a file that is never rendered |
| **U6** | The first-run dialog chain | Three steps with working handoffs (`main.js:5365-5378`). A fourth step is an addition to a pattern, not a new pattern |
| **U7** | Verification | `install.sh`, `contract-integrity-probe.sh`, `demo.sh` all exist and all run |

### Genuinely missing — no seam exists, and one has to be built

| | What is missing | Why it is missing rather than unwired |
|---|---|---|
| **M1** | **A route from the app to the interview.** | No Tauri command checks bootstrap state or starts an interview. The handler list carries `setup_status`/`run_setup`, `memory_status`/`provision_memory`, `entity_choice`/`choose_entity`/`register_entity` — and nothing for doctrine. There is nothing to wire |
| **M2** | **A bridge between the two identity stores.** | The app already asks the CEO his name and his company and stores them as `user_name` and `company_name` in its own `config.json` (`config.rs:229,270`). `provision-claude-md.sh` needs exactly those two facts as `CEO_NAME` and `COMPANY_NAME` in `engine/identity.config`, and refuses to run without them. Two stores, the same two facts, no connection — `grep -rn "provision-claude-md" app/` returns **0**. Until this exists, the app cannot provision a `CLAUDE.md` even if something told it to |
| **M3** | **Teammate spawning from the app's session.** | §4. `--setting-sources ""` excludes the only file that sets the teams flag. Without this, interview stage G3 is a no-op that reports success |
| **M4** | **A CEO-legible verification result.** | G5's contract is to show real output. There is no surface in the app that renders a probe result, and no shortened form of it. `setup_view.rs` is the register to copy — whole sentences, no paths, no digits — but it has no arm for this |
| **M5** | **A skip that is a first-class state.** | Nothing records "the CEO was offered the interview and declined." Without it, "not now" is indistinguishable from "never asked", so the offer either nags forever or vanishes forever. Both are wrong. The memory question already learned this lesson the hard way (`main.js:3538-3548`: a dialog that reopened at every launch became *"a permanent interruption"* on a first run) — do not repeat it |

### Unverified — one claim I could not settle, and how to settle it

**M0. Whether the app's inner Claude Code process loads `engine/CLAUDE.md` at
all.** Everything above assumes provisioning it would make the app's Rich read
its doctrine. The codebase asserts this in its own words at `reprime.rs:313-316`
— *"Because the engine ships `CLAUDE.md.template` (not a generated
`CLAUDE.md`), a bare `cwd=engine` boot comes up as generic Claude"* — which
plainly implies that a generated one would not. But the ordinary chat adapter
also passes `--setting-sources ""`, and I could not determine from source
whether that suppresses project context loading along with settings.

**This is the first thing to check, before any of the work below is scheduled,
because if it loads nothing then M1 is not "add a command" but "find another
way to reach Rich entirely."** The experiment is one run: provision an
`engine/CLAUDE.md` carrying a unique sentinel string, launch the app, ask Rich
something that would make it quote the sentinel, and see whether it does. That
is a fifteen-minute check and it governs the shape of everything else.

---

## 6. What I am deliberately not proposing

**The demo stays.** The CEO's words: *"The demo is definitely needed,
initially, for the user."* The interview does not replace the synthetic corpus
on the home screen, and it must not be sold on the promise that answering
questions makes his own data appear there. It will not. His own real corpus
compiles to 168 objects against the demo's 7,500, and a new customer's compiles
to zero. Any copy implying "answer these and watch your company appear" would
be a lie the product cannot cover, and the honest framing is the one in §2:
Rich writes the answers down and uses them from then on.

**No new questions.** The six stages are well-judged, they are already
conversational, and they already survive being spoken. Designing a second set
would be inventing work.

**No wizard.** The interview is a conversation and stays one. The only new
surface is the sheet that makes the offer visible.

**No form.** Every answer must reach something. The interview already routes
its answers to `CLAUDE.md`, `orchestration.config`, the roster and `ceo-wiki/`,
which is why it is onboarding and not a questionnaire. M3 is on this list
because a stage whose answers silently go nowhere would turn it back into one.

---

## 7. The bar for the one new surface

The sheet in §2 is the only new user-facing surface proposed. It inherits the
existing first-run dialogs' bar, and these are floors, not review notes:

- **Contrast: WCAG AA in both light and dark mode** — 4.5:1 for normal text,
  3:1 for large text and non-text indicators. **Computed, never eyeballed.**
  The sheet reuses the setup sheet's existing tokens; whoever implements it
  computes the ratios for both themes and states them. I am not specifying
  color values here, because a value I did not compute against the real palette
  is exactly the kind of guess this rule exists to stop.
- **Type: 18px default, 16px minimum for anything meant to be read easily,
  14px minimum for skippable text.** Nothing in this sheet is skippable — it is
  two sentences and two buttons — so nothing in it goes below 16px, and no
  exemption is claimed.
- **Voice-first: every question names its actor.** The offer copy in §2 says
  *"Rich can spend about twenty minutes asking"* rather than *"we'll ask you a
  few questions"*, because pronouns flip between reading and hearing. The same
  test applies to the two button labels: `Start` and `Not now` both survive
  being spoken.
- **American English throughout.**
- **No pagination.** The interview is a conversation and has no pages; the
  sheet is one screen and never scrolls into a second.

---

## 8. What I would settle before building anything

Four things, in order. The first two are not decisions — they are checks that
determine whether the rest of the plan is shaped correctly.

1. **Run M0's sentinel experiment.** Fifteen minutes. It governs M1's entire
   shape.
2. **Settle M3.** If the app's Rich cannot spawn Dean, decide whether the
   session gains the teams flag or whether G3 is deferred to a later,
   operator-assisted step — and if deferred, the interview must **say so to the
   CEO** rather than reporting a staffed company it did not staff.
3. **Decide what "Not now" means** (M5). My recommendation: record the
   declination durably, offer once more the next time he opens the app, and
   then never unprompted again — leaving a permanent, findable way to start it.
   The memory question's own history is the argument for this shape.
4. **Refuse Windows at download.** It is a dead end alone, it is documented as
   the one real portability gap, and discovering it at first run is the worst
   possible moment.

**None of these is a design question, which is the honest headline of this
document.** The design work — the questions, their order, their destinations,
the resumability, the honesty rules — was done, well, before tonight. What is
missing is a route from a double-clicked app to a file that already knows what
to ask.
