# Verdict: ACCEPT WITH NAMED CONDITIONS — merge `d8afbc1f`; C1, C2 and C6 are CLOSED; C3 is NOT CLOSED, and the Claude Code surface stays inactive until C7 and C8 below are met.

Reviewer: Sage (`sage-fable-r5`), 2026-09-09, on the CEO's direct order. Reviewed commit
`d8afbc1fa6e2ae717e8736fb9a683dad9b3a4661` (`codex/owned-outcome-completion`), the single commit since
`e0679a55` (`git log --oneline e0679a55..HEAD` → one line, `d8afbc1f Preserve native delegation and
recover owned work across restarts`), checked out in `/Users/alex/ab/richos-wt/sage-fable-r5`. Merge-base with
richos main (`4a6746a5`) is `e0679a55` (`git merge-base HEAD 4a6746a5`). Nothing under the Codex worktree was
written. Nothing here was implemented or fixed. Every number below carries the command that produced it or the
word `unverified:`.

Read in full before starting: the femcboost record
`femcboost/docs/reviews/structural-failure-unacceptable-results-as-user-decisions-2026-09-09.md` (private
repository, not in this tree) and `docs/reviews/sage-fable-r4-owned-outcome-2026-09-09.md` (landed on richos main
at `b6702faf`; this branch's base predates it, so that review and the r1 review it chains to are brought into this
branch byte-identical to main so the citations resolve here too). This review re-ran the
predecessor's probes rather than inheriting his results, and it does not present the CEO with a choice anywhere:
what is unfinished is named as unfinished.

## What the verdict means

**Merge-safe today, as `e0679a55` was.** The commit touches two engine libraries, their tests, one mutation
description, `dispatch.rs` (a 16 KiB registrar budget), one dead store, the harness, the documents and 489
evidence files (`git diff --stat e0679a55..HEAD` → 503 files; non-evidence: 14 files, +2,214/−67). The
unadopted engine path is unchanged: `guard-ceo-ask-first.sh` is not in the diff, and the engine suite still
passes `67/67 cases`, `27/27 properties` (`bash engine/scripts/hooks/ceo-asks.test.sh`, exit 0). No workspace on
this machine is adopted (`ls .claude/owned-work.json` in femcboost, richos, richos-hq → all `No such file`;
`~/.claude/state/richos-owned-work` → `No such file`; `readlink ~/.claude/richos-engine` → `/Users/alex/ab/richos/engine`).

**Not activatable on the Claude Code surface yet.** Two of the three activation blockers my predecessor named
are genuinely gone (C1, C2). The third (C3) is built and demonstrated on the path the trial exercised, but two
reachable behaviors on that same path are not what the assignment asks for, and both reproduce deterministically
here: a replacement session that inherits an exhausted inspection burst is refused dispatch for up to an hour
(F1), and a stray process in the dead leader's process group withholds recovery in silence (F2). Neither is a
trade-off for the CEO; each is a small, named piece of unfinished work.

## Numbers I reproduced

| Claim (RESULTS-5 / handoff) | Reproduced here | Command | Result |
|---|---|---|---|
| 1,104 Rust tests, 0 failed, 4 ignored | **Yes** | `cargo test --manifest-path app/Cargo.toml -p richos-core` (47 `test result:` lines summed) | `passed=1104 failed=0 ignored=4`, `EXIT=0`; the 4 ignored are the LIVE doctrine gate, the corpus probe and two GUI-child probes, as at R4 |
| Tauri 77 | **Yes** | `cargo test --manifest-path app/src-tauri/Cargo.toml` | `passed=77 failed=0 ignored=0`, `EXIT=0` |
| Native adapter 106 | **Yes** | `python3 engine/scripts/lib/owned-session.test.py` | `Ran 106 tests … OK`, exit 0 |
| Cached dispatch 31 | **Yes** | `python3 engine/scripts/lib/owned-dispatch.test.py` | `Ran 31 tests … OK`, exit 0 |
| Engine 67 cases, 27 mutation properties | **Yes** | `bash engine/scripts/hooks/ceo-asks.test.sh` | `67/67 cases passed`, `27/27 properties proven load-bearing`, exit 0 |
| Registration protocol 3 | **Yes** | `cargo build -p richos-core --bin richos-run` then `python3 app/scripts/test-owned-registration-protocol.py` | `bounded PASS`, `oversize PASS`, `concise-repair PASS`, exit 0 |
| Harness self-tests (no provider calls) | **Yes** | `python3 app/scripts/test-owned-wake-native.py --self-test-restart` / `--self-test-r3` / `--self-test-parser` | `PASS: 14 … restart … checks; 14 … stopped-notification …; 12 … completed-notification …; 16 … Bash-notification …`; `PASS: bounded R3 …`; `PASS: 9 native parser receipt checks`; all exit 0 |
| Escalation corpus 32 | **Yes** | `python3 app/scripts/test-owned-escalation.py` | `26 native protocol` + 3 unsupported-source + 1 replacement + 2 forge, exit 0 |
| UI 6 permission-panel + 29 assignment-panel (R4's environmental gap) | **Yes, settled** | `npm ci` in `app/ui/tests` (exit 0), then `node run-permissions.js`, `node runs.js`, `node docs-claims.js` | `grep -c PASS` → 6 and 29; all three exit 0 |
| Desktop scripted acceptance 19 phases | **Yes** | `cargo build --manifest-path app/src-tauri/Cargo.toml` (`BUILD_EXIT=0`) then `python3 app/scripts/test-owned-work-desktop.py` | `PASS actual desktop: 19 exercised phase(s)`, `SUITE_EXIT=0` |
| Final adapter `03b43e7f…`, harness `f0fe7677…`, dispatch `8592e473…` are the tree | **Yes** | `shasum -a 256` on the three files | `03b43e7fefd0…c51c75`, `f0fe7677f703…6af81b`, `8592e473c413…72003b` — match `evidence-r5/fresh-queued-final/source-identity.json` and `installer/result.json` |
| "Final fresh-session trial passed all 30 checks with zero nudges" | **Count yes; trial read, not rerun** | `python3` over `evidence-r5/*/result.json` | `fresh-queued-final: passed=True checks=30 failing=[]`; input events = one `argv` assignment plus two setup PTY keystrokes for the folder-trust dialog |
| Seven paid native trials, chronology retained | **Yes** | `ls evidence-r5` | `fresh-first-failed`, `resume-first-failed`, `resume-corrected-meter`, `fresh-corrected-meter`, `fresh-before-queued`, `resume-final`, `fresh-queued-final` = 7; every non-final `result.json` still says `passed=False` |
| Six outcome audits per final run | **Yes** | `Counter` over `audits.jsonl` | fresh: `audit-session: 6, register-native-work: 2`; resume: `audit-session: 6, register-native-work: 1` |
| Checkpoint linked 2 invocations and 38 receipts | **Yes** | `restart-ownership-evidence.json` → `replacement_states[0].completion_checkpoints[0]` | `invocations 2, receipts 38, terminals 2`; replacement `verdict complete`, `audit_attempts 0` |
| Installer in a disposable engine copy | **unverified:** read, not rerun | `evidence-r5/installer/result.json` | `exit 0`, three sidecars `true`, `production_pointer_unchanged: true`; `check.py` hard-codes the Codex worktree as its source, so I did not run it from mine — settled by Rich's `install.sh` rerun at land, which C4 requires again because both libraries changed in this commit |
| Real-provider trials | **unverified:** not rerun | — | read from `evidence-r5/*`; paid reruns were not authorized |
| The desktop "long-history fixture: 186,141 B conversation, 1,406 B envelope" | **Consistent, not reproduced** | see C2 | my equivalent on the real incident transcript is 139,478 B → 1,942 B |

Runtime: `claude --version` → `2.1.266 (Claude Code)`, the version every R5 trial records.

## Conditions from R4, ruled one by one

### C1 — CLOSED. The adopted dispatch now delivers the lead's brief beneath the host-authorized scope.

Probe (`scratchpad/probe-c1-c2.py`, fixture registrar, no model), rebuilt from the predecessor's description and
run against the **incident session's own transcript** (`5584bf8d…jsonl`, 3,334 rows, 25 human-typed rows), with
a Rich-style brief carrying the exact tokens he found missing:

```
FIRST DISPATCH: refused (SelectorRequired)
SECOND DISPATCH: allowed; prompt bytes=1942
  'cross-repo-worktree:'            in delivered prompt: True
  'model-ceiling-ack:'              in delivered prompt: True
  'MainActivity.kt:41'              in delivered prompt: True
  'no ui_v2 deletions'              in delivered prompt: True
  'inflight-ack'                    in delivered prompt: True
  '978a7d1'                         in delivered prompt: True
  'expected 10500 steps; got 1575'  in delivered prompt: True
  '```kotlin'                       in delivered prompt: True
  'REGISTERED WORK:'                in delivered prompt: True
  'LEAD OPERATIONAL BRIEF'          in delivered prompt: True
  'SOURCE CONVERSATION'             in delivered prompt: False
  'SOURCE ARCHIVE'                  in delivered prompt: True
  operational brief byte-identical after marker: True
```

Mechanism: `engine/scripts/lib/owned-dispatch.py:210-215` partitions only the first line; `:231` appends the
remainder byte for byte under `LEAD OPERATIONAL BRIEF (subordinate to registered scope)`; `:220-221` refuses a
brief that names a different `owned-work:` id (`SelectorConflict`). Pinned by
`test_operational_brief_survives_under_registered_scope` (asserts byte identity including a fenced block and
trailing newlines), `test_conflicting_selector_anywhere_in_operational_brief_is_rejected` and
`test_cli_returns_concrete_host_guidance_for_invalid_brief`. In the real final trial the engineer child received
its 5,590-byte prompt with `TASK:` and `HARD CONSTRAINTS` intact and no conversation (`result.json` →
`restart_evidence.active_child.guarded_dispatch.stdout`). The first-refusal round trip (one `SelectorRequired`
per actor per source revision — 2 refused, 2 allowed after the restart in the fresh trial) is unchanged R4
behavior and was not a condition.

### C2 — CLOSED. The conversation is no longer sent; the envelope is bounded and the boundary is honest.

Same probe, same incident transcript: registrar input `139,816` B, conversation JSON `139,478` B (the
predecessor's exact figure), delivered prompt `1,942` B with a 456-byte brief; no assistant message text present;
the dispatch receipt records `prompt_bytes`, `operational_brief_bytes: 456`, `authority_excerpt_bytes: 108`,
`source_conversation_bytes: 139478`. Boundary walk with the fixed host envelope at 1,486 B:

```
  boundary: operational 31282 B -> allowed, prompt 32768 B, brief intact=True
  boundary: operational 31283 B -> refused: Dispatch envelope exceeds 32 KiB; no text was truncated. ...
  multibyte boundary (UTF-8 bytes counted, not chars): refused
```

Behavior at the boundary is refuse-whole, never clip (`owned-dispatch.py:232-234`); the CLI stderr says so and
does not echo caller text (`test_cli_returns_concrete_host_guidance_for_invalid_brief`). So the question "can the
teammate tell it received a truncated view" has the right answer: there is no truncated view to receive. The
registered scope has its own 16 KiB budget enforced on both sides (`owned-dispatch.py:133-134`;
`dispatch.rs` `validate_native_registration`, test `oversized_registration_is_rejected_without_clipping_authority`;
protocol case `oversize PASS`), and an oversized cached record is repaired once through the registrar from the
unchanged original authority (`test_oversized_cached_scope_repairs_once_from_unchanged_original_authority`).
What C2 does not bound, and RESULTS-5 says so: the registrar still reads the whole retained source on each
changed human revision. Observation, not a finding: the teammate is handed the archive path and its sha256
(`SOURCE ARCHIVE`), so the conversation is pull-on-demand rather than pushed; that is the same exposure a
subagent already has to `~/.claude/projects/*.jsonl` on this machine, with the token cost removed.

### C3 — NOT CLOSED. Fresh-session pickup is built and demonstrated; two reachable behaviors on that path are unfinished.

**What is established.** The final fresh trial (`0pp6t7vi`) killed a leader whose child was mid-work, launched
`~/.local/bin/claude --permission-mode acceptEdits` with no prompt and no PTY input, and the replacement
(`d9f8fdd2`) saved a verified completion 406 s after the interruption (`audits.jsonl`, `kind=complete` at
`+406s`). The leader-level hook sequence from `adapter-hooks.jsonl` is the proof the predecessor asked for:

```
  t=+7s   capture  SessionStart  exit=0   (additionalContext: "This native session owns recovered unfinished obligations…")
  t=+53s  audit    SessionStart  exit=2   stderr="Rich still owns unfinished authorized work. Continue without a CEO nudge…"
  t=+54s  capture  UserPromptSubmit         (the asyncRewake wake, no human input)
  t=+157s dispatch PreToolUse    exit=0
  t=+280s audit    Stop          exit=2   (second wake)
  t=+406s audit    Stop          exit=0   (complete)
```

That settles R4's `unverified:` on whether an `asyncRewake` SessionStart hook actually wakes a session: it does,
on 2.1.266, with exit 2. The ownership journal shows `8c3ce1a1 → owner d9f8fdd2` with both processes'
pid/pgid/start identity; the replacement state carries `recovered_sessions`, `recovery_obligations` and the
consumed checkpoint. Deterministic coverage: `test_fresh_session_transfers_all_dead_assignments_with_original_sources`,
`test_active_original_or_concurrent_new_owner_cannot_be_taken`, `test_two_simultaneous_new_sessions_claim_original_only_once`,
`test_superseded_hooks_cannot_write_dispatch_tools_or_wake`, `test_completed_and_cancelled_assignments_do_not_replay`.

**Why it is not closed.** Two probes (`scratchpad/probe-c3.py`, shipped adapter, no model):

*A — restart after burst exhaustion.* Old session with `audit_attempts=5`, `retry_at=now+3000`, verdict
`incomplete`; process gone; new session boots.

```
 replacement recovered: ['old'] attempts 5 inherited delay s 3000 recovery_requires_review True event SessionStart
 native_completion_batch at SessionStart: None
 audit_once -> WOULD SLEEP (replacement SessionStart audit waits out the inherited deadline; no inspection, no wake)
 after Stop capture: checkpoint = None (old-session work cannot earn one: started_at is the new process)
 dispatch/register during window: RecoveryPending -> Recovered assignment is awaiting independent reconciliation; …
```

Three lines of code make this so: the counters and deadline are copied on transfer
(`owned-session.py:216-220`), `native_completion_batch` only looks at the new leader transcript after the new
`started_at` and only at `Stop` (`:326-331, 437, 444`), and `recovery_requires_review` refuses every `Agent`
dispatch and `SendMessage` resumption until the audit has run (`owned-dispatch.py:94-95`,
`owned-session.py:565-571`). The SessionStart audit hook is installed with a 3,900 s timeout precisely so it can
sleep the hour (`install-owned-work.py:63`). Reachable: the burst is per assignment revision (reset only at
`:541` on a new human message and `:864` on `complete`), so most of an assignment's lifetime is spent in the
hourly regime, and any crash in that regime hands the replacement the remaining delay. The passing trial never
entered it: the old leader had one Stop audit before the kill (`adapter-hooks.jsonl`, `('audit','Stop'): 1` for
`8c3ce1a1`), so `retry_at` was 15 s away. Codex's own R5 text calls an hour's wait after finished work "a
product failure" and built the checkpoint for it; the restart path is the same failure with the checkpoint
unable to fire. This is the assignment's target failure mode — the CEO restarts, sees nothing happen, types
"continue", and gets `ASSIGNMENT RECOVERY PENDING: do not repeatedly dispatch`.

*B — a stray process in the dead leader's group.* Old leader pid 101 gone; an orphaned `sleep` remains with
`pgid 101`.

```
 owner_is_live(dead claude 101, orphan sleep in pgid 101): True
 replacement recovery_obligations: None | messages: 0
 journal old owner still: old
 SessionStart additionalContext mentions withheld/recovered work: False | systemMessage: None
```

`owner_is_live` (`owned-session.py:52-61`) treats any surviving member of the leader's process group as the
leader; `recover_session` skips such entries without a trace (`:185-187`). Fail-closed is the right direction —
a live child in that group can still act — but silence is not: Rich is told nothing, and the ledger is held for as
long as the straggler lives. Reachable here: this shop has recorded background children outliving their agent and
its worktree (CLAUDE.md, 2026-07-18), and in the R5 resume trial Rich himself parked background `sleep`-style
Bash waits ("Wait for host reconciliation to settle") in exactly the group a crash would orphan. The harness
killed its own disposable process groups cleanly, so no trial saw this.

**Ruling.** Cross-session native resume exists, so the "or explicit CEO scoping" half of C3 is moot and is not
offered. The condition is NOT CLOSED because a proper implementation of restart pickup does not leave the
replacement refused for up to an hour or withhold work without saying so. Both fixes are small and are specified
under C7 and C8.

### C6 — CLOSED. Replacement fixtures present; dead code gone.

`test_pending_scope_is_not_selectable_but_independent_work_is` and
`test_revoked_old_id_cannot_select_new_independent_registration` are in the 31 (`owned-dispatch.test.py`,
both pass). `grep -n PENDING engine/scripts/lib/owned-dispatch.py` → only the stderr string
`ASSIGNMENT RECOVERY PENDING`; the constant is gone. `git diff e0679a55..HEAD -- app/src-tauri/src/owned_work.rs`
→ one line removed, `request.retry_at = now() + 30_000;`. The mutation description for
`arbitrary-brief-selector-accepted` was reworded to match the narrowed test; the mutant still kills.

### C4 (Rich, at land) — must be discharged AGAIN for this commit.

`owned-session.py` and `owned-dispatch.py` changed; richos main's sidecars still carry the R4 hashes
(`cat /Users/alex/ab/richos/engine/scripts/lib/owned-session.py.sha256` → `4d06e218…`, `owned-dispatch.py.sha256`
→ `277e0f5c…`). `bash engine/scripts/hooks/install.sh` from the landed checkout, as REVISION-5 says.

### C5 — disclosed, accurately. No policy change in R5; REVISION-5 states the `native`/`deny` semantics correctly and drops the "passthrough" word.

## The new scheduling-bug claim

**What it was.** After five inspections in one assignment revision, `retry_at` moves an hour out
(`owned-session.py:830`, `BURST_AUDITS = 5`, `RECOVERY_SECONDS = 3600`). Trial `nu04n__f` (`fresh-corrected-meter`)
spent all five while the engineer and reviewer were still working, the reviewer then finished, and the next
inspection waited on the saved deadline; the run hit its 900 s ceiling with completion unsaved. Reproduced from
the retained state: `state/dcbf74cc…json` → `attempts 5, retry_at 1788953727` = exactly 3,600 s after the fifth
audit at `1788950127`. **Reachable:** yes, in any assignment whose leader stops five times while work is in
flight, which is the ordinary shape of a Rich session.

**What pins it now.** `native_completion_batch` (`:324-468`) walks the leader transcript and nested subagent
transcripts, links `Agent`/`SendMessage` launches to their terminal receipts (native task-notification rows or
the queued `task-notification` attachment that the `ekryio6b` trial exposed), requires every current invocation
to be terminal and every fresh one to carry successful tool receipts inside its window, and returns a batch keyed
by invocation ids. At a Stop after the burst, such a batch bypasses the delay for exactly one inspection, is
consumed durably before the model call (`:806-807, 822-826`), and never refills the counter. Tests:
`test_completed_work_batch_gets_one_checkpoint_without_refilling_budget` (sleep patched to fail if the hour is
waited), `test_checkpoint_failure_consumes_once_and_preserves_failure_count`,
`test_plain_claim_human_forgery_unlinked_or_no_execution_earn_nothing` (six forgery shapes),
`test_nested_coordinator_uses_subtree_execution_and_waits_for_all_children`,
`test_duplicate_notifications_and_leader_chatter_do_not_create_checkpoint`,
`test_duplicate_capture_revision_does_not_discard_checkpoint_verdict`; the mock-inspector replay of the real saved
state (`pacing-checkpoint-replay/result.json`: `mechanical_checkpoint_available: true`, `mocked_inspection_calls: 1`,
original state sha unchanged); and the final fresh trial, where the checkpoint consumed 2 invocations with 38
receipts and the real auditor then saved `complete`.

**Limits, stated by Codex and confirmed by reading:** the checkpoint fires only at `Stop`; only for invocations
launched after the current ownership `started_at` (hence F1); only when nothing is still running, so a
long-lived background teammate blocks it; and a worker that executes useless work still earns one. All four are
the conservative direction.

## The same-session scoring correction

Original `resume-final/result.json` (`eb0nlocp`): `passed=False`, failing exactly
`no_operational_followups_measured` and `replacement_received_zero_assignment_or_nudge`. Its
`input-measurement.json` names the two "unexpected inputs": both are `<task-notification>` rows for
**background Bash** completions the leader itself launched ("Wait for host reconciliation to settle", "Wait
longer for reconciliation to complete"), carrying `tool-use-id`s and output paths. The raw input log
(`input-events.jsonl`) holds one `argv` assignment and two setup keystrokes for the folder-trust dialog, nothing
else. The companion (`restart-scoring-re-evaluation.json`: `scoring_only: true`, `provider_calls: 0`,
`original_evidence_unchanged: true`, original result sha `7ab9d0bd…`, corrected scorer `f0fe7677…`) binds those
two rows to their exact Bash launches (`matched_bound_bash_notifications`) and changes only those two checks.

**Ruling: justified, not a moved goalpost.** The check's definition — human operational input after the
assignment — did not change; the classifier stopped counting the system's own notifications as a human. The
ground truth (the PTY/argv log) was zero before and after. Two things to carry forward rather than hide: the
resume acceptance rests on adapter `dba6f917…`, not the final `03b43e7f…` (RESULTS-5 says so; the delta is the
queued-attachment carrier, covered deterministically and by saved-transcript replay), and the reason Rich was
sleeping in background Bash at all is the `RecoveryPending` gate — in the burst-exhausted case of F1 that same
polling would run for an hour.

## Findings, severity-ordered, classified

### F1 — BROKEN (activation blocker, Claude Code surface): restart after burst exhaustion refuses dispatch for up to an hour

Probe A above. `owned-session.py:216-220` (inherit `audit_attempts`/`retry_at`), `:326-331` and `:437-447`
(checkpoint scoped to the new process and to `Stop`), `owned-dispatch.py:94-95` and `owned-session.py:565-571`
(`recovery_requires_review` refuses Agent/SendMessage). Fix shape, for an engineer: on an ownership transfer that
recovers unfinished work, grant **one** immediate reconciliation inspection, consumed durably against the
transfer (record the transfer id in the state next to `completion_checkpoints`, and refuse a second for the same
transfer), so a restart loop buys at most one model call per real process death; alternatively let
`native_completion_batch` read `recovered_transcripts` with the prior session's ids so pre-crash completed work
can earn its checkpoint at the replacement's SessionStart. One test: `boot` a replacement over a state with
`audit_attempts=5, retry_at=now+3000` and assert `audit_once` calls the inspector without sleeping and that a
second boot does not.

### F2 — BROKEN (activation blocker, same surface): fail-closed pickup is silent

Probe B above. `owned-session.py:52-61`, `:185-187`. Fix shape: collect the entries skipped as live in
`recover_session`, persist them on the new state (`withheld_recoveries: [{session, pid, pgid, live_pids}]`), and
surface them in the SessionStart `additionalContext` and `systemMessage` ("unfinished owned work from session X
is withheld: process group N still has live members …"), so Rich can run `agent-liveness.sh` and reap the
straggler instead of waiting on nothing. One test: an orphan row with the dead leader's pgid must produce the
notice and no transfer.

### F3 — BROKEN, latent, unreachable today: legacy migration can never account for a live process on this runtime

`legacy_owner_process` (`owned-session.py:64-87`) compares the registry's `procStart` to `ps lstart`:

```
 pid 20597: ps started='Wed 9 Sep 09:16:05 2026' registry procStart normalized='Wed Sep 9 09:16:05 2026' equal=False
```

Token order differs, so no record ever matches; with two or more `claude` processes running the function returns
`None` forever and a legacy ledger stays "unknown ownership". It only touches ledgers written by the R4 adapter,
and none exist anywhere (`~/.claude/state/richos-owned-work` absent), so nothing is affected now. The test
(`test_legacy_ledgers_migrate_only_when_live_registry_is_accounted_for`) patches the function whole, so the format
assumption is untested against the runtime. Fix: parse both with `datetime.strptime` and compare epoch seconds,
or drop legacy migration since no legacy ledger will ever exist.

### F4 — ENVIRONMENTAL assumption: the adapter requires a `claude` ancestor by executable name

`native_owner_process` (`:39-49`) walks `ppid` until it finds a process whose executable basename is `claude`;
on this machine that is `/Users/alex/.local/bin/claude` (`ps -axo comm=` → `claude`). An npm-installed Claude
Code runs as `node` and every non-SessionStart hook would raise inside `assert_current_owner(require_process=True)`
(`:1194-1195`), which the outer handler turns into a permission/question denial or an exit-2 continuation
(`:1270-1281`). Not this shop's runtime; IMPROVEMENTS.md already lists an installer compatibility preflight. Note
it there as a hard requirement, not a suggestion.

### F5 — DUPLICATE of R4 F6, still true and now honestly worded: native cost is per changed turn

The fresh trial spent 8 paid calls (6 audits, 2 registrations) plus 2 permission denials in 406 s; the resume
trial 7 plus its reviews. REVISION-5 retracts "not every turn" for the native surface in so many words.
IMPROVEMENTS.md records the two cost items the trials exposed (a redundant reviewer dispatched by an intermediate
coordinator — visible here as 2 allowed dispatches, one by the leader and one by child `acebf877…`, for a
two-role assignment; and several inspections spent confirming a running worker had not finished yet).

### F6 — Minor (engineer housekeeping)

- A `DispatchBriefError` refusal is recorded in `owned-dispatch-reviews.jsonl` with `outcome: unverified`
  (`owned-dispatch.py:269`), while its stderr correctly says `DISPATCH BRIEF NEEDS CORRECTION`. Probe D:
  `exit 2 … ledger outcome recorded: unverified`. Record `brief_correction` instead so a ledger reader does not
  count a size refusal as a source failure.
- `SelectorConflict`'s regex `owned-work:([^\s\`"<>]+)` treats `owned-work:<same-id>,` (trailing punctuation) as a
  different id. Harmless; the guidance tells Rich to remove it.
- The `guard-ceo-ask-first.sh` 20→240 s timeout from R4 is still in `engine/hooks/hooks.json` and still lands live
  for every session on merge; unchanged since R4, noted again because C4 recurs.

## The six handoff claims, tested

1. "Preserve delegation instructions, reduce repeated context, recover unfinished work after restarts." —
   **True, with the F1/F2 residue on the third part.** C1 and C2 reproduced on the incident transcript; recovery
   demonstrated once for real and pinned deterministically.
2. "Fix the scheduling bug that could postpone final verification for an hour." — **True for the in-session
   path; it was reachable (a paid trial hit it) and is pinned by six tests, a replay and the final trial.** The
   same hour survives on the restart path (F1).
3. "Final fresh-session trial passed all 30 checks with zero nudges." — **Count reproduced: 30 of 30 `true`;
   input log holds one argv assignment and two setup keystrokes.** The trial itself was read, not rerun.
4. "Same-session resume also completed; its scoring correction and original results are documented." —
   **True and justified** (above); original retained false with hashes; adapter version disclosed.
5. "Not merged or activated yet." — **Confirmed from the filesystem** (see "What the verdict means").
6. "No universal guarantee against trivial questions in native prose." — **Correct.** What IS established: in
   the two final trials on 2.1.266 with this fixture, `question_reviews: 0`, `routine_parser_prose_asks: []`,
   `permission_denials: 2` (both routine first-attempt refusals that recovered without a prompt), zero
   operational inputs; the structured gates (`AskUserQuestion` review, permission necessity review) are
   deterministic host code; prose questions are only ever measured by a fixture-specific matcher, so the prose
   result is a measurement of this fixture, not a property of the system.

## Conditions, in order

- **C1 — CLOSED.** **C2 — CLOSED.** **C6 — CLOSED.** **C5 — disclosed.**
- **C3 — NOT CLOSED**, decomposed into:
  - **C7 (before activating Claude Code adoption):** a replacement session that recovers unfinished work must
    not inherit a refused-dispatch window; one durably consumed reconciliation inspection per real ownership
    transfer (F1). One engineer, one test.
  - **C8 (before activating):** withheld recovery must be visible to the replacement leader with the blocking
    process identities (F2). One engineer, one test.
- **C4 (at land, again):** `bash engine/scripts/hooks/install.sh` for the two changed libraries; probe BR4 goes
  red otherwise.
- **C9 (housekeeping, no severity):** F3 date parsing or removal; F4 written as a requirement; F6 items.

## For the CEO, in plain words

Is this activatable now? **No — but it is one short step away, and nothing about that step is your decision.**
The two things my predecessor said would break your teammates on day one are fixed and I reproduced the fixes on
your own incident session: every teammate now gets Rich's full brief (the worktree, the reproduced command, your
constraint in bold) underneath the registered scope, and no teammate is sent your whole conversation any more
(139 KB down to under 2 KB per spawn, with a hard 32 KB ceiling that refuses rather than trims). Restart pickup is
real: in a paid trial a leader was killed mid-work, a fresh Claude Code was started with nothing typed, and it
found the unfinished assignment, re-dispatched, and saved a verified completion in under seven minutes, on its
own. What is left is that the same pickup, if the crash happens later in an assignment, will sit and refuse to
dispatch for up to an hour before doing exactly that — which is the "type continue" moment this whole project
exists to remove — and that if a stray process from the dead session is still around, the pickup quietly does
nothing instead of telling Rich what is blocking it. Both are small, both are specified above for an engineer,
and neither needs anything from you. Merging this commit changes nothing you use today.

## What I did not do, by choice

No paid model runs; the seven native trials, the desktop trials and the semantic registration corpus were read,
not rerun. No rerun of the disposable installer check (it reads from the Codex worktree). No merge, push,
install or activation. No writes anywhere but this file and my scratchpad. Every number I did not measure is
marked as read from Codex's evidence, and every gap is marked `unverified:` with what settles it.
