# The third way a background job died — the work lease held a grant over a company scope nothing writes

Echo (Rust & Tauri desktop engineer). 2026-09-18. Worktree
`/Users/alex/ab/richos-wt/echo-opus-worklease1`, branch `cc/echo-opus-worklease1`, based on
`7bef8b0a`.

Ray's candidate-.8 on-screen audit
(`docs/verification/2026-09-18-nightly-1.2.0-20260918.2-onscreen-audit.md`, escalation
`esc-20260918T103641Z-1a073bd3`) gave three rows to this crate: §1 row 1 (BLOCKER — a background
job still cannot run), row 8 (the failure card is a broken sentence and engineer language) and row
9 (the record overwrites when a job failed). This is what each of them turned out to be.

---

## 0. Every number in Ray's audit that this work rests on, re-derived

Quoted numbers are claims with a date on them, so each was recomputed from his own two
timestamps rather than copied.

| What | His figures | Recomputed | Agrees |
|---|---|---|---|
| try 1 elapsed | 6.28 s | `10:35:49.190Z − 10:35:42.910Z` = **6.280 s** | yes |
| try 2 elapsed | 8.64 s | `10:38:49.309Z − 10:38:40.670Z` = **8.639 s** | yes |
| try 3 elapsed | 6.32 s | `10:45:54.192Z − 10:45:47.875Z` = **6.317 s** | yes |
| row 9 overwritten elapsed | 244.74 s | `10:39:47.649Z − 10:35:42.910Z` = **244.739 s** | yes |

All four reproduce. His audit's arithmetic is sound and nothing below corrects it.

**The first thing those numbers say, before any code is read:** 6.317 s is the time it takes to
spawn `claude` and answer a handshake. It is nothing like the time it takes to run a turn. So the
failure preceded the turn, and no model token was ever spent on any of the three.

---

## 1. Row 1 — the caller, which the brief marked `unverified:` and guessed wrong

The brief's candidates were *"a tool the back-end model can call, the priming, the readiness read,
or `recovery`'s scope write"*. It is none of them. It is the **grant-activation loop at the top of
`Cognition::prompt`**, and the chain is:

1. `native.rs`'s `start_work_lease` computes `scopes/{identity}-onboarding.json` and never writes
   it. **Nothing can:** `Cognition::set_onboarding_scope` is called from exactly two places,
   `spine.rs:3093` and `spine.rs:3278`, and both are the conversation's lease. Both sit behind a
   `match self.onboarding_tool_scope(binding) { Some(scope) => …, None => Ok(()) }`.
2. `spawn_with_tools` (`native.rs:1258` pre-change) put `ActionGrant::Onboarding` on the grant list
   for **every** role. Only `ActionGrant::Assignments` carried the `role == LeaseRole::Conversation`
   filter.
3. `work_host.rs:659` calls `lease.prompt(…)`. `prompt`'s first act is to open every grant in that
   list, all-or-nothing.
4. `ActionGrant::Onboarding::set(true)` → `onboarding_tools::set_actions_allowed` (`:153`) →
   `read_scope` (`:134`) → `File::open` on a path that is not there → the sentence at
   `onboarding_tools.rs:137`, returned as `CognitionError::Io`, which `cognition.rs:21` renders
   with the `cognition io:` prefix he read on the card.

There is a **second** site at `prompt`'s end (`if let Some(path) = &self.onboarding_scope`), which
`start_work_lease`'s `Some(scope)` would also have hit had the turn ever completed. Both are now
unreachable on a work lease.

### Reproduced without the screen, and probed both ways

With the two production hunks reverted, the new test
`a_work_lease_never_holds_a_grant_over_a_company_scope_nothing_writes` fails with:

```
PROBE work grants = ["onboarding", "continuity"] onboarding_scope_present=false
panicked at crates/richos-core/src/native.rs:3079:14:
a work lease's first turn must not be refused over a company scope:
  Io("Choose a company before saving interview answers.")
```

That is Ray's sentence verbatim, raised from `Cognition::prompt` on a work lease whose grant list
came from the production `spawn_with_tools`. Restored, it passes.

### The fix is a role gate, not an `exists()` guard

`ActionGrant::Assignments` has an `exists()` guard; `Onboarding` deliberately does not, and that
asymmetry is the design decision:

- On a **conversation** lease, a missing onboarding scope means no company is bound yet
  (`spine.rs`'s `None => Ok(())`). Refusing there is the check that stops a model writing company
  notes with no company chosen. **The sentence is correct in that seat.**
- The defect was never the sentence. It was a work lease standing in the seat that says it.

So arm D of the test asserts that a conversation lease with no company bound **still** fails with
exactly that sentence. Without that control, the two negatives would be a check that moved rather
than a defect that went away.

### A second thing was found on the way, and it is worse than a bad sentence

`mcp_config` mounted `richos_onboarding` **unconditionally, on every lease** (`native.rs:1060`),
while the doc four lines above it said *"`richos_onboarding` is served by the app's own executable
and is on both leases."* So the back-end model held `save_company_notes` and `decline_onboarding`
under §5.4's standing grant with **no visible turn** — a third thing the CEO's Two Riches page says
the back end must not have, beside the register and the status read. Removed. No readiness fact
moves: `work_tools_loaded` reads only the five `mcp__richos_work__*` tools (`native.rs:1504`).

### Two tests were asserting the defect

- `a_work_leases_config_omits_the_continuity_server_and_keeps_the_work_server` asserted
  `servers.get("richos_onboarding").is_some()`.
- `the_front_desk_holds_the_register_and_the_read_and_nothing_that_does_the_work` asserted the back
  end's complete server set as `["richos_onboarding", "richos_work"]`.

Both corrected, both now carrying the reason.

---

## 2. Row 8 — one live defect and one stale assertion, and the split matters

### Live: the truncation ellipsis collides with the verdict

**The brief's account of the mechanism is wrong.** It said *"the retry prefix and the failure
sentence are concatenated twice"*. They are not. It is one concatenation of two correct pieces:

- Ray's instruction was **168 characters**. `sanitize_line` caps a title at 160 and cuts on a word
  boundary, landing on *"…stopped before they"* and appending the `…` the truncation needs.
- `says::failed` then continued *"stopped before it finished."* straight off it.

Re-derived by rebuilding his title from a 168-character instruction. The join reproduces his quoted
region character for character:

```
Add a line to the notes file in the QA fixture repository saying the candidate eight walk
happened, and land it. (Third try; the first two stopped before they… stopped before it finished.
```

An ellipsis is **terminal** punctuation, so a lowercase verb phrase running on from one reads as a
sentence that broke off and restarted — on the page and aloud, which is the half that matters on a
voice-first surface.

**The module's own comment claimed the property he watched fail.** `after_title` was dropped at
`25b933f2` on the reasoning that *"every sentence in `says` continues with a word rather than a
mark, so an ellipsis is followed by a space and reads correctly."* The join is back as
`says::continues`, now against evidence that the case is real rather than hypothetical. A truncated
title closes and the verdict becomes its own sentence about *It* — an ellipsis followed by a capital
is ordinary typography for exactly this. Nothing is appended to the ellipsis; a word is inserted
after it, so candidate .7's row-8 double period cannot return through this door.

All seven sentences (`ready_to_approve`, `settled`, `failed`, `did_not_start`, `interrupted`,
`declined`, `unknown`) go through one funnel, and the test asserts the property over all nine of
their arms rather than over the one he saw.

### Stale, not broken: `cognition io:` is already off his card on main

`honest()` / `strip_engineer_prefix()` in `work_host.rs` already strip exactly
`"cognition protocol: "` and `"cognition io: "`, and `work_host.rs:746` already routes every
failure through `honest()` before it reaches a sentence.

```
8926fd937e54129f4b259e880b59309d71c5cc73  2026-09-18 10:24:43 +0100 (= 09:24:43Z)
  "The failure card names what did not happen, not the seam it came from (Ray .7 row 8)"
```

Ray walked `1.2.0-nightly.20260918.2` from 10:28Z to 10:47Z and still saw the label. That is
positive evidence the binary he walked was built **before** `8926fd93`. So this half is a stale
assertion against an older binary, not a live defect. Nothing to fix; his exact string is now
pinned by an assertion in `honest_sentence_tests` so it stays that way.

---

## 3. Row 9 — and it was worse than a wrong number on a card

`update()` stamped `updated_at_ms = now_ms()` on every call, and `take_pending_notices` goes through
`update()` purely to mark a notice delivered — a write that changes nothing about the assignment.

**The part the row did not say:** `status_tools.rs:138` publishes this field to the **front desk's
model** under the name `last_moved_at_ms`, and `status_tools.rs:195` **sorts** the open list by it.
So a delivery did not merely record a wrong elapsed time, it reordered *"what moved most recently"*
by the order notices happened to be handed over. A model reading that list was being told something
false about which job is live.

**The fix is where the field's name already pointed, so no consumer changes.** The stamp moves out
of `update()` and into `advance()`, which is the only function in the module that writes
`record.state` — verified rather than assumed: `record.state =` appears at exactly one line in
`assignment.rs`.

**No new field was needed**, although the brief asked for delivery to be recorded separately. It
already is, durably and per notice, on `Notice::delivered_at_ms` — the flag that survives a relaunch
so he is not told the same thing twice. A second delivery timestamp would have been a second copy of
a fact already on disk.

Probed: with the stamp put back, the delivery assertion fails on its own with
`left: 1789730497053  right: 1789730496996` — a 57 ms drift in a test where his was 238.459 s.

---

## 4. The whole flow, for real, on the work lease

`work_roundtrip.rs` could not be used and that is itself a finding: it drives the **conversation**
lease's `richos_work` tools, which is the pre-Two-Riches world. `mcp_config` now puts `richos_work`
on the work lease only (`native.rs:1085`), so a run of that example would fail for a reason that
says nothing about background work. Recorded, not fixed — out of this task's scope.

So `crates/richos-core/examples/work_lease_roundtrip.rs` was written. It uses the production
`spawn_work` reproduced from `src-tauri/src/main.rs`, a real delivered runtime, the real engine tree,
a real `claude` binary, and a real ECS obligation opened through the same `checkpoint` command the
front desk uses. Nothing touches the CEO's app data: the state root is a fresh temp directory.

**Environment.** macOS 24.6.0 arm64. `claude` 2.1.275 (`/Users/alex/.local/bin/claude`). Engine tree
`richos/engine` at this branch. Delivered runtime
`/Users/alex/ab/richos-rechecks/deep-20260916/runtime-archive/engine/runtime` — Python 3.13.15,
node v24.21.0, git 2.55.0, jq 1.8.2, passed `EngineRuntime::load`'s full sha256 inventory. There is
**no delivered runtime inside any engine checkout on this machine and no installed `/Applications/RichOS.app`**,
so the runtime had to come from an existing extracted delivery; it is read-only to this probe.

### Run 1 — cut off by my own budget, and it produced the instrumentation

```
FIXTURE BEFORE  head=e06bbe73baf9a7237a8665ccdd48b38e6b15a5d1
REGISTERED 132fd7d9-786f-4c91-8f4a-e0a5d4e90ab3 at t+0
STATE Registered -> Preparing at t+0.229s :: Opening the work connection.
STATE Preparing -> Running  at t+2.890s :: The back end has started on it.
  final_state: Running   fixture_gained_a_commit: false   watched: 420.099s
  final_detail: "The work connection's records could not be read, so this counts as still running."
```

The 420 s budget was mine and it was wrong: `work_roundtrip`'s own permission responder allows
**1800 s**, so a full prepare → worker → review → integrate cycle was never going to fit. The run
also showed that a **state-only** watcher is blind — the state sat at `Running` while the detail had
silently become the settle reading's sentence. The probe now records every detail change with its
own timestamp.

### Run 2 — 1500 s budget, fixture retained

```
FIXTURE BEFORE  head=e68b288c8fbbd5d88c0088872c48b3b252735774
  e68b288 the fixture's starting state
  cc7a7d3 Initialize repository
  notes.txt = "hello\n"
Obligation opened: {"accepted":true,"applied":1,…,"record_id":"qa-notes-line","status":"applied"}
REGISTERED 298e35dd-9526-406a-90a4-cb40dee8346e at t+0
t+   0.009s  Registered :: Written down. Preparation has not started.
t+   0.216s  Preparing  :: Opening the work connection.
t+   2.277s  Preparing  :: Preparing the workspace and starting the work.
t+   2.486s  Running    :: The back end has started on it.
```

```
t+ 350.207s  Running    :: The work connection's records could not be read, so this counts as
                           still running.
FIXTURE AFTER   head=e68b288c8fbbd5d88c0088872c48b3b252735774   (unchanged)
  notes.txt = "hello\n"                                         (unchanged)
  reached_running: true    running_at_seconds: 2.485632166
  work_session: 81007c9a-b0f6-433d-807e-4b9238e34aec
  final_state: Running    fixture_gained_a_commit: false    notices: []
  watched_for_seconds: 1500.053884958
```

**The fixture gained no commit.** Why, established from the run's own captured evidence and not
inferred — see §5.

**Row 9's fix is visible in this run, which is better evidence than its unit test.** Each transition
carries its own `updated_at_ms`: `…728233`, `…728241`, `…730336`, `…730596`, `…078273`. After the last
state/detail change at t+350.207 s the record was re-read roughly 5,750 more times over the following
**1,150 s** and `updated_at_ms` never moved off `1789732078273`. Before this change any write would
have dragged it forward.

**And the work lease's live `--mcp-config`, read off the running process table, is the fix itself:**

```
--strict-mcp-config --mcp-config {"mcpServers":{"richos_work":{...}}}
```

One server. No `richos_onboarding`. That is `native.rs`'s role gate observed in a real child rather
than in a test.

**The engine plugin did load**, which is the positive control on the readiness gate: the session's
`callbacks.jsonl` holds a `SessionStart` row, a `UserPromptSubmit` row, 12 `PreToolUse`, 10
`PostToolUse` and 1 `PostToolUseFailure`. The brief reached the back end intact and correctly, quoted
from `guard-transcript.jsonl`:

> "This is a background assignment from the CEO. Carry it out with the desktop work tools.
> Repositories: …/qa-fixture — The assignment: Add a line to the notes file and land it — Carry it
> through to the end: do the work, get an independent review, land the reviewed result, and close the
> assignment. Do not ask him to approve the land — that is your job, not his. …"

### What this establishes, and what it does not

**Established: the blocker class Ray hit is cleared.** All three of his failures were at or before
the first turn (6.280 s, 8.639 s, 6.317 s) and every one left `work_session: null` — the lease never
took a turn. Here the assignment reaches `Running` at **t+2.486 s**, and `Running` is written from
one place only, on the arrival of the back end's own first stream item — a positive signal from the
child, never elapsed time and never silence. `work_session` is written down. The §52 sequence he
never saw on screen — *written down → opening → preparing → the back end has started on it* — is on
the record with a timestamp against each line.

**Not established: nothing here is a claim about the on-screen walk.** This is a headless probe. It
says the work lease's own path works; it says nothing about the opening screen, the Return key, the
timeline render or anything else in Ray's audit.

---

## 5. The next blocker, found by the run and raised as `esc-20260918T115854Z-852c5f9c`

Fixing row 1 got the job as far as taking its turn. The next thing it hits, **every detail below read
out of the run's own `callbacks.jsonl`**:

1. `brief_for` (`work_host.rs:1601-1610`) tells the back end the **repositories** and the **title**.
   It never names the **obligation id**.
2. `mcp__richos_work__prepare` requires one. The back end called `mcp__richos_work__inspect` *first*
   (call #5 of 27, before `prepare` at #17), still invented `obligation_id: "obl-add-notes-line"`
   where the real obligation was `qa-notes-line`, and the engine refused it in **8 ms**:
   `error: "item is absent or outside the active scope"`.
3. No work receipt was ever written — `engine-state/work-receipts` is empty — so no worker, no review,
   no land.
4. The turn then ended, and the settle reading wrote *"The work connection's records could not be
   read, so this counts as still running"* at **t+350.207 s**. The assignment sat in `Running` for the
   remaining 1,150 s with **`notices: []`**.

**Point 4 is the worse half.** A job whose turn has ENDED and whose receipt cannot be read is not
still running, and the CEO was told nothing at all — which is worse for him than the failure card Ray
complained about, because a card at least ends the wait.

**The model was not confused about the job.** The worker brief it wrote was correct and specific:
*"In notes.txt (currently a single line "hello"), append one new line at the end … Keep the existing
"hello" line unchanged and make sure the file ends with a trailing newline. Change nothing else.
Commit … Validation: `git diff HEAD~1 -- notes.txt` shows exactly one added line and no removed
lines."* It was blocked purely on not being able to name the obligation it was working on. After the
refusal it fell back to `Bash` (calls #21–27) rather than the work tools, which would have bypassed
the review and integrate gates had it got that far.

**Decided by the lead on this escalation, recorded here so the next slice inherits it rather than
re-deciding it:** the **app** hands the obligation id to the back end in the **work scope**
`richos_work` already reads — the model never types identifiers, since a brief that named one would
only invite another invented one — and `richos_work.prepare` derives it from the scope, refusing only
when the scope carries none. Separately, a settle reading that cannot read the receipt **after the
turn has ended** is a **failure with a notice to the CEO**, never "still running" forever. Both go to
the next slice, not this one.

---

## 6. Observed and deliberately not changed

- **`start_work_lease` and `start_with_engine` write a continuity stub that cannot be read back.**
  Both write `{"version":1,"actions_allowed":false}`, which cannot deserialize into
  `ecs::ToolScope` — `bridge` and `binding` are required and the struct is
  `#[serde(deny_unknown_fields)]`. It is **latent, not live**: on both leases the stub is replaced
  by a full `ecs::write_scope` before any prompt reaches the grant loop (`bind_work_assignment` on
  the work lease, `prepare_work_turn` on the conversation's), and `work_host.rs`'s `run_one` binds
  before it prompts. Named here rather than changed, because changing it touches a path two other
  teammates are in and nothing today can reach it.
- **`work_roundtrip.rs` is stale** — see §4.
- The dropped `after_title` helper's removal commit `25b933f2` reasoned from a property the code did
  not have. The replacement carries the evidence, not just the fix.

---

## 7. Test hygiene

- `cargo test -p richos-core`: baseline **1229 passed / 0 failed**; after this work **1232 passed /
  0 failed** (+3 new tests), confirmed on two consecutive full runs.
- `cargo check` in `src-tauri`: `Finished`, 4 pre-existing dead-code warnings (`nav.rs` and
  unrelated), none from this work.
- One flake seen and it is not this work:
  `work_host::tests::registering_returns_before_the_work_starts_and_the_work_still_runs` failed once
  at **110.535292 ms** against its own 100 ms ceiling under full parallel load, then passed alone and
  on both subsequent full runs. It is load-sensitive, and the row-9 change **removes** a `now_ms()`
  call from the registration path rather than adding one, so it cannot have slowed it.
- Every one of the three new tests was probed against the pre-fix code and seen to fail with the
  defect's own signature, then seen to pass restored. Two of my own test assertions were too loose on
  first writing and were tightened rather than the production code loosened.

## 8. Instance hygiene

No RichOS app instance was launched by this work: it is a headless crate probe, not a walk.
`pgrep -fl 'RichOS.app/Contents/MacOS/richos-tauri'` returned nothing at the start of the session and
nothing at the end. Two transient `richos-tauri` children of another teammate's reaper test were seen
under `$TMPDIR` (pids 45943 and 47857) and had exited on their own within the same minute; neither was
mine and neither survived. The probe's scratch state root is removed on the way out unless
`RICHOS_PROBE_KEEP_FIXTURE` is set. Run 2's fixture was retained on purpose so its evidence could be
read, and was then removed by hand: `richos-work-lease-c881b7ca…` under `$TMPDIR`, 472 KB, and
`ls -d …/richos-work-lease-*` afterwards reports that no such scratch remains. Nothing of this work is
left in a temp directory (CEO §54).

## 9. Commits

Oldest first, on `cc/echo-opus-worklease1`:

| SHA | What |
|---|---|
| `1888150f` | The work lease never holds a grant over a company scope nothing writes (row 1) |
| `a0cd127c` | A truncated title never collides with the verdict that continues from it (row 8) |
| `60421690` | When an assignment last moved survives its notice being delivered (row 9) |
| `ddc4fbd0` | A probe that drives the WORK lease, because `work_roundtrip` no longer does |

**Hunk in another teammate's file, named for sequencing:** `work_host.rs` gains four assertion lines
and a comment inside the existing `honest_sentence_tests` module (commit `a0cd127c`). Test-only, no
production line touched. `echo-opus-screenwait1` is also in `work_host.rs`.
