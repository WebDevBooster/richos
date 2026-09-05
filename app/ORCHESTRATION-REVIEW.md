# RichOS durable work: fifth review

## Problem and target

Rich must own an accepted assignment until its complete outcome is verified.
A model ending a turn, losing its process or falsely saying “done” cannot count as
completion. Routine execution choices belong to Rich. CEO authority is needed
for material business decisions, including whether to spend more resources on
work that repeatedly fails to converge.

This branch targets RichOS desktop. The original incident occurred in a Claude
Code team in femcboost; this change installs no hooks there. Claude Code does not
impose the one-refusal limit discussed in the first proposal. That was a local
engine policy. The architectural reason for a durable controller is ownership
outside individual inference turns, not an alleged provider Stop-hook limit.

## What the fourth audit established

The previous revision restored Rich's conversation, speech and working state and
made corrections reach live work. Its registration mechanism was still wrong:
every message incurred private inference on Rich's expensive conversation lease,
with forced priming before and after it. The reviewer measured a roughly seven
second conversation lock after an answer and four lease turns per ordinary
message. Malformed registration retried indefinitely and inconsistent
classification had no host check. Recovery had a delay but no finite budget.
The earlier document understated those costs. Those findings were valid.

## Registration after Rich answers

Typed and spoken messages still enter `Spine::submit_prompt`. Rich answers using
his normal primed session. New answered or interrupted CEO turns enter a durable
inbox derived from the conversation ledger. Installation records a baseline so
historical conversations are not executed. Discovery keeps an in-memory cursor,
tracks unresolved turns and rereads only pending requests after its initial scan.
It rebuilds that index from durable files on restart.

A separate registrar receives the CEO message, Rich's delivered reply, the last
six CEO/reply pairs and the conversation's assignment snapshots as JSON data.
It has no access to Spine and never holds its mutex. The registrar defaults to
`haiku`; operators can override `RICHOS_REGISTRATION_MODEL`. Its native process
uses an empty temporary directory, no tools, empty MCP configuration, empty
settings sources and a strict result schema. Unexpected permission callbacks
are denied. The settings exclusion is limited to this tool-free transcriber;
acting workers retain configured user, project and local restrictions.

Registration makes separate claims about CEO intent and Rich's commitment. The
host requires exact nonempty quotes from both current messages and checks their
consistency. Discussion with a commitment, action without one, invented targets,
missing pending decisions and unknown fields are rejected. Corrections must
identify their assignment. The registrar cannot produce task descriptions or
acceptance criteria: the host copies the **entire request and Rich reply** into
the execution and review contract, preserving negative constraints. Amendments
also retain the previous scope except where the CEO explicitly changes it.

Rich's priming now requires him to state the complete deliverable and acceptance
constraints aloud. Only a missing-scope result permits one targeted scope repair
through Rich. Ordinary registration never calls or re-primes his lease. Reports
reuse an already primed conversation; a scope change primes the appropriate
thread, tracked independently of the thread selected in the UI.

This still uses fallible model judgment. Quotes establish provenance, not proof
that a classification is semantically correct. Consistent mistakes remain
possible. The code does not claim mathematical detection of every missed intent.
The detached registrar still costs one inference per answered CEO message,
including discussion. Rich still delegates small actions, so even a small edit
pays registration, independent checks and a worker if needed.

## Failure bounds and retained ownership

Registration permits at most three attempts, charged durably **before** inference.
A crash cannot erase a charged attempt. Failures wait 30 seconds before retry.
Missing scope permits at most one additional Rich clarification within that
registration budget. At exhaustion, the request remains saved and unfinished,
a report explains the internal failure and automatic registration stops. It does
not ask the CEO to debug the registrar. A later corrected request can proceed;
fixing and replaying the failed inbox entry is an operator repair, not a hidden
infinite retry loop. No worker starts from an invalid registration.

Autonomous execution uses a persisted resource budget of ten cycles per task
between explicit CEO authorizations. A cycle includes a worker attempt when
needed and independent verification. Review transport failures retain review-only
state, consuming the same budget without rerunning the worker. Charging precedes
inference, including the crash window. At five unsuccessful cycles, the
controller itself sets an hour delay and Rich reports progress. At ten, unfinished
work becomes `NeedsDecision` asking whether to authorize up to ten more cycles,
revise the scope or end it. Restart and the Resume button cannot grant that
resource authorization. The actual answer and receipt are retained verbatim.

This is a cycle and time-budget limit, not a dollar cap. Generated plans allow
at most 1,800 seconds per worker and 300 seconds per check. A one-task desktop
contract therefore allows at most ten workers and ten checks per authorization
batch, usually fewer because the first cycle checks existing results. Native
startup and conversation/report turns have their own transport behavior.
Actual monetary charges depend on the provider and context.

Notices have stable identities and at most three conversational delivery attempts.
If Rich cannot deliver a notice, an explicitly labeled host status is recorded
and displayed instead. That fallback is not synthesized speech by Rich. Completed
notices are not repeated on restart. Neither a reporting failure nor a repeated
checkpoint silently creates unlimited additional model calls.

## Independent assignments and controls

Each assignment has its own journal. An existing paused, waiting or decision-bound
assignment does not prevent another assignment in the same conversation from
being registered and scheduled. Workers remain serial globally. An active worker
therefore still occupies its bounded attempt until it yields; this is not a
parallel worker scheduler.

A correction identifies its job, requests interruption and applies a numbered
amendment once that writer yields. Existing effects are independently rechecked.
The Work plan panel lists assignments separately. Controls send the displayed
run identity so a newer assignment cannot redirect a click to a different job.
Resuming autonomous work returns it to the detached scheduler.

The American English spelling is `Canceled` in Rust and `canceled` on the wire and
in journals. This unshipped experimental format has no compatibility alias for
the former spelling. Existing experimental journals require migration or intact
archival before reuse. The conversation ledger's vocabulary is unchanged.

## Permissions and remaining limits

Managed workers retain user, project and local settings. The app permits local
edits and sandboxed shell commands and denies requests for further authority.
Within that policy, workers can delete files in their workspace. There is no
per-action approval, automatic undo or external-action transaction outbox.
Independent model review cannot guarantee sound business judgment or exactly-once
arbitrary external effects.

The app must be open to execute. It resumes saved work on launch but installs no
background OS service and adopts no existing interactive Claude Code team.
Conversation and spoken reports still serialize on the conversation lease.
Registration and worker inference do not. Large assignment snapshots and long
individual messages are not yet covered by a production-scale load measurement.
The live/reloaded proactive report styling seam from the fourth audit remains;
the ledger source and speech delivery are correct, but their visual presentation
has not received a separate reconciliation in this revision.

The Work plan panel, including its new selector, still needs independent design
review. P4 is open. No design approval, production deployment or main-branch merge
is claimed. Validation below is evidence for the code paths tested, not a promise
that no future operational failure can occur.

## Review entry points

| Concern | Code |
| --- | --- |
| Conversation entry and voice | `src-tauri/src/main.rs` |
| Detached registration and consistency checks | `crates/richos-core/src/registration.rs` |
| Native tool and permission boundary | `crates/richos-core/src/native.rs` |
| Inbox, discovery, scheduling and report recovery | `src-tauri/src/owned_work.rs` |
| Cycle budget, amendments and independent checks | `crates/richos-core/src/run.rs` |
| Conversation scope and spoken reports | `crates/richos-core/src/spine.rs` |
| Assignment selection and controls | `src-tauri/src/managed_runs.rs`, `ui/runs.js` |
| Evidence and reproduction | `managed-run-validation.md` |

The strongest remaining objection is that the host still relies on two models
agreeing correctly about authorization and completion. The durable state machine
prevents silent loss at a turn boundary and bounds recovery costs; it cannot make
those judgments infallible. This revision makes that dependency and its failure
limits explicit instead of hiding them behind a green engine test count.
