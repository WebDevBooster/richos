# RichOS owned-work review

## Problem and intended product behavior

The CEO should be able to say “Handle this.” Rich, the Chief of Staff & Business
Operations Lead, should determine the routine details, own the resulting work
and continue until the complete outcome is verified. Only a material decision
requiring CEO authority should be escalated. A model ending its turn is not a
reason to abandon the work.

The supplied incident was an interactive Claude Code team in the femcboost
repository. Its orchestrator claimed that nothing was unblocked despite actual
available backlog work. The stop guard accepted that declaration. The guard
also had its own one-refusal escape, separate from the provider's hook policy.

The target of this branch is RichOS. It does not change the live femcboost
session or install another hook into it. Repository work is one use of the
RichOS controller, rather than the definition of the product.

## Why a stop guard is insufficient

A guard can reject a bad stopping claim. It cannot own a request after the app
exits, recover a lost worker, schedule another conversation or independently
establish delivery. That ownership belongs in the application. Hooks remain
useful checks inside execution, but are not the application scheduler.

The architecture does not depend on an alleged single-refusal limit in Claude
Code. The engine's own one-refusal choice and Claude Code's documented Stop
behavior are different contracts. Consult the current [Claude hook
reference](https://code.claude.com/docs/en/hooks) for provider behavior.

## What changed after the audits

The earlier implementation required a hand-prepared JSON plan and left failed
attempts for an operator to inspect and retry. That was a controller foundation,
not the requested Chief of Staff workflow. This revision adds the missing
conversation intake and desktop owner.

1. The real `send_message` command persists an owned request. Voice and steering
   use the same ownership path. Ordinary questions can receive a direct answer;
   work requests become declarative plans after workspace discovery.
2. A startup scheduler services the request spool and unfinished jobs across
   conversations. It survives an app restart through disk state. Worker output
   stays bound to the originating company when another conversation is selected.
3. Generated plans contain independent, read-only outcome reviews rather than
   model-authored executable verifier commands. Review output uses the native
   structured-result field, not a guess extracted from visible commentary.
4. Operational retries retain ownership and persist backoff. Explicit pauses
   remain paused. CEO decisions have their own state and require a question,
   justification, options and a recommendation. Answers are stored verbatim.
5. Managed execution can perform ordinary file edits and sandboxed shell work
   without user-written allow rules. It retains configured restrictions and
   denies permissions requiring additional authority. It does not approve all
   requests or strip settings sources.
6. Managed output uses the existing `proactive` ledger source. This removes the
   downgrade hazard introduced by the experimental `managed` enum value.
7. Existing missing-workspace cancellation and corrupt-journal archive controls
   remain. The file picker meets the type floor and is an optional import path,
   rather than the primary workflow.
8. The documentation-count check now uses the exact README command line it
   matched. Previously it selected an earlier prose mention and failed despite
   the count being correct. The prior validation record overstated that check.

The [usage and permission contract](MANAGED-RUNS.md) describes the implemented paths
and their limits. In particular, retaining settings also retains the provider's
array-merge semantics. This is not a claim of VM isolation or arbitrary external
transaction safety.

## Code map

| Concern | Source |
| --- | --- |
| Durable state, dependencies, retries and completion | `crates/richos-core/src/run.rs` |
| Intake, structured inspector and declarative criteria | `crates/richos-core/src/autonomy.rs` |
| Native settings, sandbox policy and structured results | `crates/richos-core/src/native.rs` |
| Worker execution and independent checks | `crates/richos-core/src/run_host.rs` |
| Scoped conversation worker adapter | `crates/richos-core/src/run_spine.rs` |
| Compatible receipts, output and steering transfer | `crates/richos-core/src/spine.rs`, `ledger.rs` |
| Desktop request spool and startup scheduler | `src-tauri/src/owned_work.rs` |
| Actual message entry and app startup | `src-tauri/src/main.rs` |
| Run controls and projection | `src-tauri/src/managed_runs.rs`, `ui/runs.js` |

## Verification and failures found during development

The detailed command record is in [managed-run-validation.md](managed-run-validation.md).
Do not equate a successful compilation with a passed behavioral test. A portable measured summary is checked in at `validation/owned-work/results.json`; the UI suite results are beside it.

The actual desktop integration harness is
`scripts/test-owned-work-desktop.py`. It boots the desktop, invokes its actual
message command and exits before inference. A second boot selects another
company's conversation. Its native fixture first says “All done” without
creating the deliverable. The test requires another attempt, the correct file,
exactly one CEO request after restart, a verified completion message and no
output in the other company. This test has passed. It also tests recovery of a completion notice lost after the job committed its verified result.

The fixture itself initially matched a task string inside priming context and
performed two actions in one attempt. A second version failed to extract text
from the native input content array. Both produced failing assertions; neither
was counted as proof of continuation. The corrected fixture matches the actual
task prompt and extracts the protocol's text blocks.

Installed Claude testing first established that a managed worker can write a
real file without editing settings and that the host verifies its exact content.
A natural-language trial then exposed reviewer commentary breaking JSON parsing.
A later probe established that native structured output can terminate with
`tool_use`; that is accepted only when a structured result actually exists.
Timeouts and failed trials remain failures in the evidence record.

## Remaining limits reviewers should challenge

Independent model review is stronger than accepting the worker's claim, but is
not infallible or adversarially independent of workspace evidence. General
external actions still need available tools, authority and an idempotency
strategy. This branch does not implement an external-action outbox or guarantee
exactly-once effects after a hard process crash.

Workers are scheduled serially. RichOS does not adopt an existing Claude Code
team. The app must be open to execute and restarts work when it is launched
again. The terminal intake is not yet persisted before planning, unlike the
desktop intake. These are real boundaries, not successful outcomes in disguise.

The strongest objection is that application ownership alone cannot make every
business task finish: a bad scope, weak criteria, missing capabilities or a
wrong escalation judgment can still defeat the intended outcome. The claim to
verify is narrower and executable: an accepted desktop request does not lose
its owner merely because a worker returned, a check failed, a conversation
changed or the app restarted. Anything broader needs additional evidence.
