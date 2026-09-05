# RichOS durable work: fourth review

## Problem

Rich must own an accepted assignment until its complete outcome is verified.
A worker ending a turn, losing its process or falsely saying “done” must not
abandon the assignment. Routine execution choices belong to Rich. Genuine CEO
tradeoffs must be distinguishable from operational failures.

The original incident was a Claude Code team in femcboost. This branch targets
RichOS, not that interactive session. It installs no hooks into femcboost.

## What the third audit got right

The third revision built a working controller but replaced the conversation
entry path with a fresh classifier. That bypassed Rich's established session,
mislabelled answers as outreach, broke the speech path and prevented corrections
from changing running work. Passing controller tests did not establish that the
product integration was correct. The earlier completion summary understated this.

This revision restores `Spine::submit_prompt` for typed and spoken input and
`reconcile_intake` for steering recovery. Rich's normal priming, streaming,
working state, voice source and conversation session remain on the input path.

## Handoff behind Rich

Rich receives and answers the CEO normally. The conversation ledger persists
that turn before inference. A background reconciler discovers new answered or
interrupted CEO turns and requests a private registration from **the same Rich
lease**, with full company-scoped priming. It does not launch a separate intake
inspector to answer the CEO.

The private response is a typed instruction: no assignment, new work, a complete
revision to existing work, a decision answer or explicit cancellation. It is
saved before a job is created or changed. Questions remain conversation replies;
registration JSON is neither displayed nor spoken. On restart the durable
ledger and saved registration allow the handoff to recover. Installation records
a baseline so old conversations are not retroactively executed.

This is an explicit implementation tradeoff: registration is a private follow-up
turn on Rich's session, after his conversational answer. It costs extra inference
and depends on Rich's judgment. It is not a new native tool callable mid-turn.
The host persists the handoff before execution, but cannot prove that every model
classification or conversational claim is correct.

Rich is instructed to delegate even small actions and acknowledge responsibility
without claiming completion. A new handoff independently checks existing results
before starting a worker. The real desktop trial showed why this matters: Rich
initially performed a small edit himself, then the old path redundantly ran a
worker. Pre-execution review prevents duplication when the complete result is
already present. This does not guarantee exactly-once arbitrary external effects.

## Execution and corrections

Desktop workers run on independent governed leases. They receive scoped Rich
context, but never borrow the conversation lease or hold its mutex during work
or review. Rich can answer in another conversation while a worker is busy.

A correction reaches Rich normally. He registers a complete amended assignment.
The host requests interruption of its worker, applies the amendment at the safe
boundary and independently rechecks existing effects under the revised criteria.
No Pause-then-End sequence is required. Explicit user pauses remain distinct.
Cancellation cannot undo an external action already in flight.

Amendments are journalled as numbered contract revisions with a new receipt.
Reopening permits only the explicit revision shape, unchanged workspace and
reset verification state. Ordinary unexplained contract changes remain errors.
Completion and decision notices include the contract revision in their identity.

## Review and recovery

Intake and review use separate schemas. Each variant requires its fields and
refuses sibling fields. Native schemas use a required object envelope containing
the appropriate union. The host validates the typed result as well. See the
[Claude structured-output contract](https://code.claude.com/docs/en/agent-sdk/structured-outputs).

A review transport or parsing failure preserves a review-only retry state across
restart. It does not rerun the executor. A valid incomplete verdict requests more
work. A genuine decision verdict stops only the affected work for CEO authority.

After five unsuccessful execution or review cycles, Rich reports the problem and
his recovery approach through the conversation. Recovery at that checkpoint is
spaced one hour apart. Ownership is retained; the CEO is not asked to click retry.
This is a reporting and rate-control policy, not an automatic finite-cost bound
or proof that the next approach will succeed.

Results and decision requests are spoken by Rich through the normal chunk stream.
Ordinary replies retain their original source. Background reports may correctly
use the existing proactive ledger vocabulary. The experimental `managed` alias
was removed, resolving the third audit's forward-compatibility test collision.

## Permissions and product boundaries

Managed workers retain user, project and local restrictions. The app permits
local edits and sandboxed shell commands and denies callbacks requiring further
authority. Within that policy a worker can delete files in its workspace; there
is no per-action approval or automatic undo. Provider settings merge semantics
and sandbox support still apply. This is not a VM or an external-action outbox.

A company without a project folder receives an execution directory under app data.
This no longer rewrites its configured root list merely because a message arrived.
The app must be open to execute and resumes saved work on launch. It does not
install a background OS service, adopt an existing Claude Code team or implement
parallel worker scheduling.

The existing Work plan panel remains available for inspection and explicit
controls. This revision does not claim independent product/design sign-off for
that panel. No deployment or main-branch merge is included.

## Evidence and review entry points

See [managed-run-validation.md](managed-run-validation.md) for measured runs,
failures and coverage boundaries. Small portable summaries live in
`validation/owned-work/`. The reproducible desktop harness now tests normal
conversation, restart recovery, false completion, cross-company responsiveness
and a correction to running work.

| Concern | Code |
| --- | --- |
| Conversation entry and voice | `src-tauri/src/main.rs` |
| Rich's private registration and streamed reports | `crates/richos-core/src/spine.rs` |
| Handoff spool, independent worker and recovery reports | `src-tauri/src/owned_work.rs` |
| Review-only retries and explicit amendments | `crates/richos-core/src/run.rs` |
| Typed schemas and independent reviewer | `crates/richos-core/src/autonomy.rs` |
| Governed native execution | `crates/richos-core/src/native.rs` |
| Regression proofs | `crates/richos-core/tests/run_tests.rs`, `scripts/test-owned-work-desktop.py` |

The strongest remaining objection is that durable ownership and independent
model review cannot guarantee sound business judgment, correct scope or safe
external transactions. The measurable claim is continued ownership across
worker stops, failed reviews, corrections and app restarts while preserving
Rich's conversation. Broader guarantees require broader capabilities and evidence.
