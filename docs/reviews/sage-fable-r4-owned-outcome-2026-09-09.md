# Verdict: ACCEPT WITH NAMED CONDITIONS — merge `e0679a55`; do not activate the Claude Code surface until conditions C1–C3 are met.

Reviewer: Sage (`sage-fable-r4`), 2026-09-09, on the CEO's direct order. Reviewed commit
`e0679a553c6462b7e882135028577304f7f59faa` (`codex/owned-outcome-completion`), checked out in
`/Users/alex/ab/richos-wt/sage-fable-r4`. Merge-base with main: `28f07ab53a3dc8835eab49c670584120560ab3b9`
(`git merge-base main HEAD`). Four commits: `b80f9978`, `2b9d7122`, `5f519822`, `e0679a55`. Nothing under
the Codex worktree was written. Nothing here was implemented or fixed. Every number below carries the
command that produced it, or the word `unverified:`.

Specification reviewed against: `/Users/alex/ab/richos-hq/docs/plans/rich-owned-outcome-2026-09-08.md`,
read in full before the delivery. Predecessor reviews read: the in-tree `SAGE-REVIEW.md` (its author then
wrote code now under review), and the three external reviews (`sage-fable-r1`, `r2`, `r3`).

## What the verdict means

**Merge-safe today.** The unadopted engine path is the old gate plus one JSON existence check
(`engine/scripts/lib/owned-work-policy.sh:3-12`, `engine/scripts/hooks/guard-ceo-ask-first.sh:157-170`);
`OWN4` and nine `OWN-CFG` cases pin that, and all 67 engine cases plus 27 mutation properties pass here.
No repository on this machine carries `.claude/owned-work.json`; the desktop needs a rebuilt app; the native
adapter reaches a session only through its installer. Merging changes nothing a session does — with the
two exceptions in C4.

**Not activatable on the Claude Code surface yet.** The adopted dispatch path discards the lead's brief
(C1), injects the whole session conversation into every spawn (C2), and does not resume unfinished native
work after a restart that yields a new session id (C3). The desktop surface is in materially better shape
than the native one, and that is the wrong way around for the assignment: the incident happened in Claude
Code, and the native side is where the assignment's own words are still short.

## Numbers I reproduced

| Claim (RESULTS-4 / handoff) | Reproduced here | Command | Result |
|---|---|---|---|
| 1,103 Rust tests, 0 failed, 4 ignored | **Yes** | `cargo test --manifest-path app/Cargo.toml -p richos-core` (log: 47 `test result:` lines summed) | `passed=1103 failed=0 ignored=4`, `EXIT=0`; the 4 ignored are the LIVE doctrine gate, a corpus probe and two GUI-child probes — not-run, not passes |
| Engine: 67 cases, 27 mutation checks | **Yes** | `bash engine/scripts/hooks/ceo-asks.test.sh` | `67/67 cases passed`, `27/27 properties proven load-bearing`, exit 0 |
| Native adapter 74 | **Yes** | `python3 engine/scripts/lib/owned-session.test.py` | `Ran 74 tests … OK`, exit 0 |
| Cached dispatch 19 | **Yes** | `python3 engine/scripts/lib/owned-dispatch.test.py` | `Ran 19 tests … OK`, exit 0 |
| Escalation corpus 32 | **Yes** | `cargo build -p richos-core --bin richos-run` (sha256 `385970b6…2a982d`) then `python3 app/scripts/test-owned-escalation.py` | `26 native protocol` + 3 unsupported-source + 1 replacement + 2 forge = 32, exit 0 |
| Tauri side (pending-instruction + command helpers) | **Yes** | `cargo test --manifest-path app/src-tauri/Cargo.toml` | `passed=77 failed=0 ignored=0`, exit 0; the six `owned_work::pending_instruction_tests::*` all `ok` |
| Desktop scripted acceptance, 19 phases | **Yes** | `cargo build --manifest-path app/src-tauri/Cargo.toml` (`BUILD_EXIT=0`) then `python3 app/scripts/test-owned-work-desktop.py` | `PASS actual desktop: 19 exercised phase(s)` including `pending-cancel`, `registration-failures-restart`, `disposition-missing-resume`, `disposition-interrupted-resume`; `SUITE_EXIT=0` |
| UI: docs-claims | **Yes** | `node app/ui/tests/docs-claims.js` | exit 0 |
| UI: 6 permission-panel + 29 assignment-panel checks | **unverified:** environmental | `node app/ui/tests/run-permissions.js`, `node app/ui/tests/runs.js` | both exit 1: `Error: playwright not found. Run npm install in app/ui/tests` — settled by `npm install` there and rerunning |
| Source identity of the review tree | **Yes** | `shasum -a 256` on five delivered files vs `evidence-r4/final-source-identity.json` | `owned-session.py 4d06e218…`, `owned-dispatch.py 277e0f5c…`, `native_permission.rs 2f02c6b0…`, `owned_work.rs e4f350e9…`, `guard-ceo-ask-first.sh a0f67412…` all match |
| Doctrine unchanged since the R2 GREEN release-gate run | **Yes** | `git diff --stat 2b9d7122..HEAD -- app/crates/richos-core/doctrine/` | empty — the R2 gate result carries forward on identical bytes (it measures doctrine only, headless, no hooks) |
| Real-provider trials (native ×6, desktop ×2, semantic corpus 10) | **unverified:** not rerun | read from `evidence-r4/*/result.json` and companions | `native-timing/result.json` `passed:false` (1 meter), `resumed-agent-re-evaluation.json` `passed:true`, 24 checks; `native-exact-prefix/result.json` `passed:false`, its `invocation-boundary-re-evaluation.json` `passed:true`, outcome `permission_required`; `desktop-live-scope/native-measurements.json` `operator_followups:0`, `question_tool_calls:0`, `run_worker_attempts:1` — settled only by paid reruns, which the brief did not authorize |
| R4 native-mutation harnesses | **unverified:** not rerun | — | dirs `evidence-r4/richos-r4-native-mutations-*` exist; settled by running the harness named in their logs |

Runtime measured: `claude --version` → `2.1.266 (Claude Code)` (RESULTS-4 says the desktop trial used
2.1.266; the adapter's provenance allowlist was written against 2.1.263).

## The claim that matters most, tested against a real transcript

The entire native design rests on `human_row()` (`engine/scripts/lib/owned-session.py:112-122`): a CEO
message is authority only if the transcript row carries `origin == {'kind':'human'}`, `promptSource ==
'typed'`, a `uuid` and a `promptId`, and none of its text parts contains an XML-like tag
(`plain_human_part`, `:125-131`); a row with an attached wrapper is demoted whole to
`mixed_native_context` (`:171-174`) and cannot be cited. If those fields did not exist in real transcripts,
every dispatch under adoption would be refused. I ran the shipped functions over the incident session
itself (`scratchpad/probe-provenance.py`, deterministic, no model):

```
=== PROBE TRANSCRIPT: …/5584bf8d-6ff7-4db2-86a3-745f2e130c42.jsonl
user rows: 335
user row (origin.kind, promptSource, has promptId): {('human','typed',True): 25, (None,None,True): 300, ('task-notification','system',True): 10}
source_messages provenance: {('user','native_human_typed_v1'): 25, ('assistant','native_assistant'): 190, …}
human rows: 25 plain: 25 mixed(demoted to context): 0
```

All 25 CEO turns are recognized; none is demoted; the 300 tool-result rows and 10 task notifications are
correctly not authority; two subagent transcripts (`promptSource: 'sdk'`) yield zero human rows. This
closes the prior r3 review's Finding 4 (prefix denylist) with an allowlist, and it holds on this machine's
actual runtime. Fragility to note, not a defect: the check is dict-equality on `origin`, so a future Claude
Code adding a key to `origin` fails closed (every dispatch refused with `CEO DEPENDENCY UNVERIFIED`) until
the adapter is updated; IMPROVEMENTS.md already lists a version handshake.

## Findings, severity-ordered, classified

### F1 — BROKEN for this shop (activation blocker, Claude Code surface): the adopted dispatch discards the lead's brief

`engine/scripts/lib/owned-dispatch.py:181-193`: the first line of Rich's Agent prompt must be
`owned-work:<id>`; the host then builds a new prompt from the registrar's brief plus the conversation JSON
(`:187-190`) and replaces the caller's prompt entirely (`:191`, `updated = dict(proposed, prompt=prompt)`).
Without the selector the call is refused (`:184`, `SelectorRequired`, exit 2), and since the installer wires
no `register` mode (`engine/scripts/install-owned-work.py:59-84`), the only way Rich learns the ids is that
refusal's stderr (`:220-226`). Deterministic demonstration (`scratchpad/probe-prompt-replacement.py`, fixture
registrar, no model):

```
FIRST DISPATCH: refused (SelectorRequired)
SECOND DISPATCH: allowed; prompt length 821
  'cross-repo-worktree:'    in delivered prompt: False
  'model-ceiling-ack:'      in delivered prompt: False
  'MainActivity.kt:41'      in delivered prompt: False
  'no ui_v2 deletions'      in delivered prompt: False
  'inflight-ack'            in delivered prompt: False
  'REGISTERED WORK:'        in delivered prompt: True
  'SOURCE CONVERSATION'     in delivered prompt: True
```

What the teammate loses: the worktree path (`cross-repo-worktree:` is read by the guards from the
*original* input, so the spawn passes, but the agent that boots never sees where it is supposed to work),
the reproduced command and its output, the file:line, the CEO's bold constraint, the ack contract. This
contradicts three standing rules in `femcboost/CLAUDE.md` ("Your spawn prompt carries the whole task", "A
NUMBER IN A BRIEF CARRIES THE COMMAND THAT PRODUCED IT", the `cross-repo-worktree:` line) and would
re-create a 2026-09-06-style blocked-spawn day on activation. The intent — a brief cannot self-authorize —
is right and the r3 review asked for it. The mechanism went one step too far.

Fix shape (describe, not implement): keep the host-authorized header (`HOST-AUTHORIZED WORKSPACE`,
`REGISTERED WORK`, the citations) and append the caller's prose *beneath* it, labeled as the lead's
operational brief and subordinate to the registered scope; validate that the caller prose does not name a
different `owned-work:` id. The registrar's brief stays the authority; Rich's brief stays the instructions.
One test in `owned-dispatch.test.py` asserting the caller's `cross-repo-worktree:` line survives.

### F2 — BROKEN (activation blocker, same surface): every adopted spawn carries the whole session conversation

`owned-dispatch.py:190` embeds `json.dumps(data['messages'])` — every human and assistant message of the
session — into every teammate prompt, uncapped. Measured on the incident session
(`scratchpad/probe-conversation-size.py`): `source messages = 217 ; JSON bytes = 139478 ; approx tokens =
34869` per dispatch. That is a cost line item on every spawn and hands every teammate the CEO's entire
conversation, including business context unrelated to its task. The same payload goes to Sonnet on each
re-registration (`:155-156`; capped only at 4 MiB in `richos-run.rs`). Fix shape: pass only the cited
source messages plus a bounded tail, or a host-authored digest with citations.

### F3 — Change 3 not met on the native surface (disclosed, but the assignment's words are literal): "After a restart, unfinished assignments resume"

State is keyed by `(workspace, session_id)` (`owned-session.py:94-97`); a new session starts an empty
state (`:226`); nothing scans prior sessions. So `claude --resume` (same id) continues; a fresh `claude`
does not. The desktop side does resume (journal plus `owned_work.rs` recovery; reproduced above in the
`registration-failures-restart` and `disposition-interrupted-resume` phases). RESULTS-4 and IMPROVEMENTS.md
say so plainly. Classification: **not broken — unbuilt**, and it is the CEO's third change on the surface
where his incident happened. Either build the cross-session pickup (a SessionStart scan of
`~/.claude/state/richos-owned-work` for unfinished ledgers bound to this workspace, presented as owned
work) or have the CEO explicitly accept that native restart resume means `--resume` only. **unverified:**
whether `asyncRewake` on the installed `SessionStart` audit hook (`install-owned-work.py:63-65`) actually
wakes a resumed session — settled by one `--resume` against a state holding an `incomplete` verdict.

### F4 — DUPLICATE of the r2/r3 open CEO question, decided by the engineer

Both prior reviews named one decision as the CEO's: does the adapter answer permission prompts on his
behalf? R3 made `native` = pass-through. R4 changed `native` again: the first attempt of every
un-preauthorized call is refused (`owned-session.py:690-692` requires `prior_count >= 1` before any
review; `:749` denies otherwise), a repeat with necessity evidence buys a Sonnet review
(`native_permission.rs:102-115`), and only a `native_prompt` disposition lets the dialog stand
(`native_permission.rs:96-99` requires literal exact-operation authority or a distinct failed alternative
from the same actor). No CEO ruling exists; REVISION-4 discloses the change. It is arguably within change
3's "recoverable failures trigger diagnosis and another approach", and the design is sound — but it was
flagged as his twice, so it goes to him as a disclosure (C5), not a blocker. The residual limit is real and
documented: Claude draws the dialog before the hook returns, so a routine prompt can flash
(`evidence-r4/native-exact-prefix/early-termination.json`).

### F5 — OBSOLETE with partial replacement: 16 deterministic dependency cases removed from the engine suite

`git diff 5f519822..HEAD -- engine/scripts/hooks/ceo-asks.test.sh` removes 42 case-title lines and adds 10;
gone are `OWN5–OWN9` and `OWN13–OWN18` (unresolved authority holds dispatch; ask receipt does not authorize;
cited answer clears; revoked answer re-holds; source change during review invalidates). Their mechanism
(`audit-dispatch`, per-dispatch classification) was retired, so they are obsolete — correctly. The
replacement is the one-shot real-model registration corpus (`app/scripts/test-owned-dispatch.py`, 10
cases: `missing_signing_authority`, `later_revocation`, `peer_claim_cannot_answer` …) plus
`owned-dispatch.test.py` (stale selector after a new human instruction). What no deterministic test now
pins: that a scope the registrar returns in `pending` is not selectable, and that a later revocation
invalidates an earlier `work` id. Structurally true today (only `work` entries get ids,
`owned-dispatch.py:163`; revision mismatch refuses, `:178`), but change 4 says obsolete tests need
replacement coverage — two fixture cases would do it. Related dead code: `PENDING`
(`owned-dispatch.py:15`) is defined and never printed.

### F6 — Claim 4 ("Sonnet at checkpoints, not every turn") is true on the desktop and overstated on native

Desktop: a `discussion` receipt closes intake with no model call (`owned_work.rs:520-524`); work registers
once. Native: every `Stop` whose fingerprint changed runs `audit-session`
(`owned-session.py:397-399, 421`) — five in a burst, then hourly (`:417`); every new CEO message changes
`source_revision`, so the next dispatch re-registers (`owned-dispatch.py:134-135, 155`); every
`AskUserQuestion` runs `audit-question`; every repeated permission request with evidence runs a necessity
review. On the Claude Code surface that is close to one Sonnet call per turn plus one per changed-source
dispatch. Not broken; the table in REVISION-4 is honest about the boundaries, the handoff sentence is not.

### F7 — ENVIRONMENTAL: UI suites not runnable here

`playwright not found` (both exits 1, heads in `scratchpad/ui-*.log`). README documents `npm install`. Not
a defect in the delivery; the 6 + 29 UI numbers stay unverified in this review.

### F8 — The CEO's composed release gate has not been run on the native surface

His gate: stale records, obsolete tests, genuine defects, interrupted workers and an unrelated pending CEO
decision, no nudges, plus restart recovery, real model runs. The R4 native trial
(`evidence-r4/native-timing/request.txt`) composes a genuine defect, an obsolete assertion, an unchanged
backlog and an engineer-plus-review procedure; the pending-decision ingredient lives only in the
registration corpus; interrupted workers and restart recovery only in the desktop scripted phases.
`engine/gates/unmanaged-assignment` on richos main was last run GREEN at R2 on doctrine bytes that are
unchanged (verified above), and it measures doctrine without hooks. Codex's own line stands: claim it only
for the surfaces and conditions demonstrated. That is what this verdict does.

### Minor (engineer housekeeping, no severity)

- `owned_work.rs:407` `request.retry_at = now() + 30_000;` is dead — overwritten at `:411`.
- `guard-ceo-ask-first.sh` timeout 20→240 s in `engine/hooks/hooks.json:116` applies to every session at
  next boot, adopted or not; harmless on the unadopted path (it exits fast) but it is a live change.

## The six assignment points

1. **Authority policy and reconciliation.** Doctrine text exists (`app/crates/richos-core/doctrine/owned-outcome.md`
   lines 1–7, 31–41; `inner-doctrine.md` "Own the work"). The engine reconciliation is real under adoption:
   the per-session question quota is replaced by registrar-decided scope (`guard-ceo-ask-first.sh:164-169`),
   reminders keep the decision visible without blocking (`notice-ceo-unasked.sh:192-196`,
   `session-start-ceo-ask.sh:134-138`, `ceo-asks-status.sh:102-111`). Unadopted behavior unchanged (OWN4,
   OWN-CFG1–9). **Met**, subject to F1/F2 on what a dispatch then carries.
2. **Durable obligation.** Desktop: `record_work_disposition` receipt bound to turn/thread/entity/workspace/nonce
   (`work_disposition.rs:14-45`, atomic no-replace `:225-280`); missing receipt → registrar recovery, no
   resend (`owned_work.rs:385-397` reserves the deadline before inference; `registration.rs:186-188` 30 s ×3
   then hourly). Native: ledger keyed by verified source revision (`owned-dispatch.py:125-172`). **Met.**
3. **Continuation is the controller's.** Desktop: controller reconciles permission responses and resumes
   (`permission.rs:59-86`; run test `durable_response_is_reconciled_after_restart_without_an_operational_nudge`).
   Native: Stop-hook audit with `asyncRewake` (`owned-session.py:377-461`), host-authored continuation
   (`:359-374`), pacing (`:409-418`). Restart: desktop yes; native only `--resume` (F3). Background service:
   not built, disclosed, and the assignment made it conditional ("if you expect…"). **Met on desktop;
   partial on native.**
4. **Diagnosis against current requirements.** Doctrine (`owned-outcome.md:9-22`) and the audit criteria
   (`richos-run.rs` `criteria:` block) demand the broken/obsolete/environmental/duplicate split and reject
   inspection as execution. The native trial's `request.txt` requires `obsolete_assertion` vs
   `implementation_defect` classification and `independent-diagnosis.json` is retained. Codex applied the
   axis to its own fixtures (SAGE-REVIEW.md "Combined desktop fixture diagnosis"; RESULTS-4 "obsolete
   scripted prompt matcher"). **Met.**
5. **Independent verification.** Host-side: `verify_with_inspector` rejects `Decision` unless a second
   challenge cites the retained CEO source and declares independent work finished
   (`autonomy.rs:290-300, 324-340`); the native path admits a decision only when the CLI stamped
   `escalation_validated` (`owned-session.py:425-434`), which closes the r3 Finding 5 channel; the r3
   mutation survivors are now named properties (`registrar-nonzero-json-trusted`,
   `dispatch-success-receipt-dropped`, both in the 27). This document is the human half. **Met**, with F8's
   scoping.
6. **Operating surfaces.** Installer plus adapter make a Claude Code leader an owned worker of the same
   verifier (`install-owned-work.py`, `owned-session.py`, `richos-run audit-session`); managed RichOS
   workers are excluded from recursive ownership (`RICHOS_OWNED_WORK_HOST`). Migration of outstanding
   work/authority into RichOS: not built, listed in IMPROVEMENTS.md. **Integration built; migration
   transfer not built and explicitly outside — which the assignment allows if it is explicit.** It is.

## The seven handoff claims

1. "Rich records work explicitly; verified authority is reused." — True. `spine.rs:162` instructs the
   receipt; reuse via receipt (desktop) and revision-keyed ledger (native).
2. "Routine failures trigger recovery instead of requiring your answer." — True on the tested paths;
   `permission_denial` with recovery text (`owned-session.py:503-521, 650`); desktop `report()` says the CEO
   need not resend (`owned_work.rs:437-441`).
3. "Genuine permissions have a separate, exact-operation approval mechanism." — True for managed workers:
   `permission.rs` binds run/task/plan revision/authority revision/workspace/tool/full input, consumes
   before allow, refuses storage inside workspace or temp (`:65-67`), hard-deny honored (`:209-213`). 16
   tests pass in the 1,103. A business answer cannot grant
   (`controller_displays_actual_request_business_answer_cannot_grant…`).
4. "Sonnet at defined checkpoints, not every turn." — Desktop true; native overstated (F6).
5. Validation counts — reproduced except the Playwright pair (F7) and the paid trials (read, not rerun).
6. Stated limitation (dialog flash) — disclosed; it is not the only one of its shape. Same shape, same
   surface: F3 (no cross-session resume) and F1/F2 (what a dispatch carries). The assignment's words tolerate
   the flash (recovery without an answer is what change 3 asks); they do not tolerate F3 as written.
7. "Production has not been activated." — Confirmed: `ls` finds no `.claude/owned-work.json` in femcboost,
   richos or richos-hq; no `~/.claude/state/richos-owned-work`; `~/.claude/richos-engine ->
   /Users/alex/ab/richos/engine` (main, which lacks `owned-*` libs). **What activating changes:** (a) merging
   to richos main puts the modified guard, hooks timeout and three new lib files into the live engine at
   the next session boot — unadopted behavior identical, but `install.sh` must rerun or probe BR4 goes red
   (sidecars are gitignored); (b) adopting a workspace requires `python3 engine/scripts/install-owned-work.py
   <workspace> <richos-run> [--permission-policy native|deny]`, which appends ten hook entries to that
   workspace's `.claude/settings.local.json` and writes `.claude/owned-work.json` — in femcboost
   `settings.local.json` is a committed file (CLAUDE.md, "still committed and still the single registration
   source"), and the installer excludes only `owned-work.json` and its lock from git
   (`install-owned-work.py:24`), so adoption dirties a tracked file; (c) the desktop needs the rebuilt app.

## What the in-tree Sage authored, and whether it holds

SAGE-REVIEW.md names his edits; REVISION-2 adds that he authored the R2 engine changes (the regex
recognizer, since deleted in R3 — nothing of it survives at `e0679a55`). What survives and was checked line
by line, harder than the rest:

| His fix | Where now | Holds? |
|---|---|---|
| Pending requests get non-executing target views; later unresolved instructions fence older creation | `owned_work.rs:105-129` (`pending_assignment`, `pending_followup`), `:493-506` (`creation_has_unresolved_followup`), `:630-633` | Yes. `pending_assignment` has `tasks: vec![]` so it can never be driven; the fence delays an unstarted assignment while a later turn in the same thread is unclassified. Cost he named himself: with a missing receipt on the later turn that delay is the registrar retry (30 s ×3, then hourly). Tested: `newer_unclassified_instruction_fences_recovery_but_other_company_does_not` ok |
| Durable cancellation marker before superseding | `:465-470` (`.cancel` saved first, then `done`), checked first at `:509-511` | Yes. `pending_cancellation_is_targetable_and_durable_before_recovery` ok; desktop phase `pending-cancel` PASS |
| Empty interrupted reply registrable | `registration.rs:80-85` | Yes. Accepts only `reply_quote` empty AND `!rich_committed`; a fabricated reply quote still fails |
| Repeated corrections keep the original scope | `registration.rs:126-128` (`previous` = target goal, chained into the new goal and criteria) | Yes. `pending_correction_supersedes_original_without_losing_its_prohibition` ok |
| Retry deadline reserved before inference; failures precharged | `owned_work.rs:385-397`, refund at `:400` | Yes; desktop phases `registration-failures` and `registration-failures-restart` PASS. One dead store at `:407` (cosmetic) |
| Explicit pause survives a correction | `:606-612` captures `preserve_pause`; `:653-655` `amend_with_pause` | Yes; the atomic API is Echo's, the desktop capture is his |
| Fixture change: two provider-failure cases in separate conversations | `test-owned-work-desktop.py` | Correct diagnosis — the old assertion was obsolete under his own fence; production logic unchanged |

Verdict on his work: it holds. The independence problem was real and is now discharged by this review; I
found no line of his that I would have written differently for correctness, one dead store, and one
disclosed cost (the same-thread fence) that is the right trade.

## Conditions, in order

- **C1 (before activating Claude Code adoption):** the adopted dispatch must deliver the lead's brief to
  the teammate beneath the host-authorized scope (F1). Blocker for this shop; one engineer, one test.
- **C2 (before activating):** bound the conversation payload per dispatch (F2).
- **C3 (before activating, or CEO acceptance in writing):** cross-session native resume, or the explicit
  scoping that native restart resume means `--resume` only (F3).
- **C4 (at land):** rerun the engine `install.sh` for the three new sidecars; note the live guard timeout
  change.
- **C5 (disclosure to the CEO, not a question):** the permission policy now in the code (F4).
- **C6 (engineer housekeeping):** replacement fixture cases for F5; dead `PENDING`; dead store `:407`.

## For the CEO, in plain words

You would be accepting a real, tested step: the desktop app now keeps an assignment alive from the moment
you give it until it is verified done, recovers on its own when the intake or a worker fails, asks you only
for exact, one-time permissions it cannot get any other way, and no longer needs you to resend anything.
The engine no longer makes Rich ask you an unrelated prepared question before he can dispatch — in a
repository that opts in. What you would not yet be accepting is the same guarantee inside Claude Code,
where your incident actually happened: the piece that connects Claude Code is built and it works in its
trials, but as designed today it throws away the brief Rich writes for each teammate, sends every teammate
your whole conversation, and does not pick unfinished work back up after a plain restart. Those three are
named above with the fix shape; none is large. Nothing is switched on by merging this. The engineer also
chose, without a ruling from you, that in an opted-in Claude Code workspace a routine permission request is
refused once so Rich finds another way, and a real prompt is shown only after a separate check says it is
necessary; a dialog can still flash briefly. If you want prompts to simply reach you as prompts, that is one
installer flag.

## What I did not do, by choice

No paid model runs: no rerun of the six native trials, the two desktop trials, or the ten-case semantic
corpus (`test-owned-dispatch.py` refuses without `--runner`; it would spend nine Sonnet calls). No rerun of
the R4 native mutation harnesses. No `contract-integrity-probe`. No `npm install` for the UI suites. No
merge, push, install or activation. Every number I did not measure is marked as read from Codex's
evidence, and every gap is marked `unverified:` with what settles it.
