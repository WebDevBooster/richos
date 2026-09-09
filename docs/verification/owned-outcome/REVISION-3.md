# Revision 3 acceptance contract

This document freezes the correction scope in response to the
[external R2 review of record](/Users/alex/ab/richos-hq/docs/carry-forward/sage-fable-r2-review-of-record.md).
The reviewed commit was `2b9d7122`. All implementation remains in the existing
`codex/owned-outcome-completion` worktree. This document states required behavior
and evidence, not results. No R3 test pass, deployment or completion is asserted
here. Results must identify the tested source and surface before being added.
Current evidence and pending acceptance work are recorded in [RESULTS-3.md](RESULTS-3.md).

[REVISION-2.md](REVISION-2.md), its evidence index and the earlier RED samples remain
historical records. R3 does not rewrite an earlier failure as a pass. The external
review reproduced a failing native trial despite GREEN doctrine-only gates. Those
surfaces measure different things and must remain separate.

## Required native runtime corrections

### Auditor isolation

The read-only inspector cannot establish the leader's effective permissions from
its own tool availability. An inspector saying that Bash is disabled must never
become a host assertion that Bash is disabled for the leader.

Raw reviewer prose, including `remaining`, question-denial explanations and raw
inspection exceptions, stays in diagnostics rather than being copied into
leader-facing instructions. Continuation uses host-authored instructions and
observations with explicit actor and source identity. Native call/result receipts
may describe the particular leader or child operation observed. They do not prove
a global permission policy. Configured rules may be reported as observed settings,
not as an inferred complete map of effective permissions.

Acceptance requires an adversarial reviewer response that contains the observed
false restriction. The raw diagnostic must remain recoverable while the restriction
cannot enter the leader's wake or denial instructions. The same boundary must hold
on inspector failure. Real execution refusals must remain attributable to their
actual actor and operation; isolation must not discard required failure evidence
or turn missing execution into completion.

### Native permission policy

The default native `PermissionRequest` path observes the request and passes through
to Claude's existing permission handling. A request is not itself a denial or an
approval. The adapter must preserve the native UI's ability to receive a real human
grant, including requests originating in native child work. Errors in this observer
must not silently install the previous blanket-denial policy.

The adapter grants no tools automatically and changes no existing allow or deny
rule. Work already covered by the operator's permissions proceeds under those
permissions. A request to handle a task does not override an explicit tool denial.
An explicit deny-only opt-in may suppress dialogs, but its operational consequence
must be disclosed: work requiring a new grant cannot obtain it through that mode.
That choice must not become the default without an operator decision.

Acceptance must distinguish an observed prompt, a real grant, a refusal and an
unresolved prompt. Tests must exercise default passthrough and explicit deny-only
behavior, including child and error paths. A business answer, asking a question or
a proposed permission-rule suggestion must never count as a tool grant.

### Dependency classification

The replacement for the prose recognizer is a tool-free semantic review of the
actual dispatch and relevant source context. Its classification must cite checked
source fragments. Its output does not grant business or tool authority.

The external false positives must be allowed when their source supports independence:
"in no way depends", "nothing here is blocked" and a historical dependency explicitly
superseded by the current instruction. The external ordinary-English dependency
cases must be refused while authority remains unresolved, including "hasn't answered",
"cannot proceed without his ruling" and "waiting for the CEO's answer".

Current source context must affect the disposition. A question having been asked,
a deferral note or a TODO disappearing cannot replace an actual answer. Missing or
unreadable evidence must be reported honestly; an unrelated pending decision must
not become a blanket hold on independent work. Genuine decisions remain visible
with options and a recommendation while independent work continues.

Acceptance includes the external reproductions and behavior-changing mutants.
Tests must fail if source reads become decorative or a marker always refuses
regardless of relevant authority. Matching changed refusal wording is insufficient.
Malformed review, invalid citations and a source change during review cannot be
silently treated as a verified disposition. Passing these cases demonstrates the
measured cases, not perfect understanding of every English brief.

## Native trial measurements

`operational_followups` must be derived from actual input events, not assigned a
constant. Preserve the event log and identify fixture/setup actions, genuine human
permission grants, business answers and routine operational nudges separately.
A run that needed an operational answer cannot claim zero operational follow-ups.

Also measure routine questions emitted in ordinary assistant prose. Filtering
`AskUserQuestion` does not cover that channel. A run that asks the CEO to resolve
routine implementation or permission setup, then eventually finishes without an
answer, may demonstrate recovery. It does not demonstrate zero routine questions.
The literal zero-routine-question claim still requires zero such questions on the
observed surface. A display-only replacement is not a correction to work ownership.

Keep these cases separate:

- A fixture with the parser route preauthorized tests recovery within that declared
  permission configuration. It cannot establish behavior without that grant.
- A fixture without parser-specific preauthorization tests the default permission
  boundary. Record any prompt, grant or refusal that actually occurs. Do not add a
  hidden parser allow rule or supply an unrecorded operational answer to make it pass.

For each run retain its original assignment, permissions, adapter configuration,
source/binary identity, input log, native transcript, tool execution receipts,
auditor decisions and final artifacts. Record every failed or undecidable outcome.
A new sample after an implementation change must name the changed version and keep
the earlier sample. Do not repeatedly sample unchanged behavior until a favorable
vote appears.

Required executed validation needs actual execution evidence. An externally parsed
artifact or a correct-looking file does not establish that the worker ran the
requested check. Likewise, process exit zero, eventual completion and a GREEN
headless doctrine gate do not establish the composed interactive acceptance claim.

## Managed permission grants remain a separate substantial requirement

Restoring native passthrough does not fix RichOS-managed permission requests. The
managed callback in `app/crates/richos-core/src/native.rs` still denies requests
outside its automatic policy. `RunController::apply_answer` saves a business answer
and resumes work but does not create a tool grant. This is an identified remaining
product requirement, not an implemented R3 fix or an optional cosmetic improvement.
It must not be hidden inside an unrelated native correction.

A bounded correct bridge can reuse the existing decision panel and its run/question
identity fences, plus the host-owned atomic scope-file pattern used by onboarding.
It needs a host-created pending operation bound to the run, task, current plan,
canonical workspace, exact tool input and unique request identity. Approval must be
a typed approve-once action for that displayed operation. An ordinary business
answer, resource continuation or model-written recommendation cannot mint a grant.

The worker may consume only a matching grant. Inspectors and hidden context cannot
consume one. Persist grant state and consume before returning permission to the
worker. An unconsumed grant can survive restart while its exact scope remains
current. A consumed grant cannot replay after an ambiguous crash; inspect actual
effects first. Cancellation and changed scope invalidate unused grants. Hard
configured denials remain binding.

Expected implementation surfaces are `app/crates/richos-core/src/native.rs`,
`app/crates/richos-core/src/run_host.rs`, `app/crates/richos-core/src/run.rs`,
`app/src-tauri/src/owned_work.rs`, `app/src-tauri/src/managed_runs.rs`,
`app/src-tauri/src/run_view.rs` and `app/ui/runs.js`. Reusable patterns are
`onboarding_tools.rs::write_scope`, the existing decision receipt and revision
checks, and the panel's typed command routing. The onboarding `actions_allowed`
boolean is too broad to reuse as the grant model.

This bridge requires explicit validation of changed arguments/workspace/revision,
forged business answers, duplicate consumption, crash recovery, inspector isolation
and pause/end behavior. It is not a callback switch from deny to unconditional
allow. No R3 completion claim may imply that this bridge already exists.

## Scope and reporting boundary

R3 contains the observed native isolation, permission-policy, dependency-classification
and measurement corrections above. It does not introduce all-message routing, a new
agent framework, an OS background service or automatic cross-session ownership
transfer. Other suggestions belong in [IMPROVEMENTS.md](IMPROVEMENTS.md).

Report implemented changes, deterministic evidence, real-provider evidence,
remaining requirements and installed integration separately. Until the relevant
measurements are supplied, their status is unverified. Eventual recovery alone is
not the CEO's requested no-babysitting outcome.
