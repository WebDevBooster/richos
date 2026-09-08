# RichOS durable work: architecture and review history

The September 8 continuation correction is documented in
[Owned outcome completion](../docs/verification/owned-outcome/REVIEW.md).
That report covers the separate native Claude adapter, recovery corrections,
current verification and activation limits. Earlier audit observations below are
historical measurements; the current behavior is stated explicitly here.

## Problem and target

Rich must own an accepted assignment until its complete outcome is verified.
A model ending a turn, losing its process or falsely saying “done” cannot count as
completion. Routine execution choices belong to Rich. CEO authority is needed
for material business decisions, including whether to spend more resources on
work that repeatedly fails to converge.

The original implementation targeted RichOS desktop. The incident occurred in a
Claude Code team in femcboost. The September 8 correction adds an optional native
continuation adapter, tested in disposable workspaces; it is not installed in
femcboost by preparing this branch. The one-refusal limit discussed in the first proposal was a local engine policy.
Claude Code does have a documented limit of eight consecutive Stop-hook blocks,
confirmed from the [raw hooks reference](https://code.claude.com/docs/en/hooks.md)
on 2026-09-05. The ordinary RichOS conversation lease excludes settings sources
and loads no plugin Stop hook. Its durable controller must therefore own work
outside inference turns; it is not a replacement for an existing desktop hook.

## What the fourth audit established

The fourth revision restored Rich's conversation, speech and working state and
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

## What the fifth audit changed

The previous single live pass did not establish reliable default-tier behavior.
Sage reproduced two failed jobs in four Haiku trials: a quote check rejected
ordinary Markdown acknowledgments three times, then halted the assignment.
Another trial required an unnecessary scope restatement. Those failures were
real and contradict treating one passing run as sufficient release evidence.

The default is now Sonnet, retaining the operator override. Quote matching
normalizes whitespace only, permitting collapsed blank lines and wrapped bullets.
The quote must still be a contiguous fragment of its own current message;
stitched passages, changed wording and cross-message evidence remain invalid.
The prompt requests one short fragment rather than a copied specification.
Unit and desktop fixtures now exercise multiline Markdown, with mutations for
both over-strict whitespace matching and acceptance of invented quotes. A native
probe measures the shipped prompt and default tier across designed cases and
repeated Markdown inputs without executing work.

Rich is asked to acknowledge the deliverable and essential constraints in one
concise prose paragraph, without headings, lists or filesystem paths. The full
CEO request and previous scope remain in the contract, so brevity does not discard
constraints. Failed-start reports receive a plain-language status, never the raw
registration error or component names. Diagnostics remain in the saved request.
The September 8 correction retains scheduled recovery after registration failure.
The CEO does not need to resend the request. A report describes the unfinished
state and scheduled retry without blaming the original brief.

A separate registrar receives the CEO message, Rich's delivered reply, the last
six CEO/reply pairs and the conversation's assignment snapshots as JSON data.
It has no access to Spine and never holds its mutex. The registrar defaults to
`sonnet`; operators can override `RICHOS_REGISTRATION_MODEL`. Its native process
uses an empty temporary directory, no tools, empty MCP configuration, empty
settings sources and a strict result schema. Unexpected permission callbacks
are denied. The settings exclusion is limited to this tool-free transcriber;
acting workers retain configured user, project and local restrictions.

Registration makes separate claims about CEO intent and Rich's commitment. The
host requires contiguous quotes from the current messages, allowing whitespace
differences and checks their consistency. An actually empty interrupted reply
permits an empty reply quote only without a claimed Rich commitment. Discussion
with a commitment, invented targets, missing pending decisions and unknown fields
are rejected. An authorized action remains work even if Rich asks whether to start.
Corrections must
identify their assignment. The registrar cannot produce task descriptions or
acceptance criteria: the host copies the **entire request and Rich reply** into
the execution and review contract, preserving negative constraints. Amendments
also retain the complete previous scope chain except where the CEO explicitly
changes it. Pending requests are valid amendment and cancellation targets.

Rich's priming requires a concise acknowledgment of the deliverable and essential
constraints. Routine discovery does not require a scope restatement or Rich's
acceptance of an already authorized action. Ordinary registration never calls or
re-primes his lease. Reports
reuse an already primed conversation; a scope change primes the appropriate
thread, tracked independently of the thread selected in the UI.

We retain priming on each thread switch because the payload is thread-scoped.
Reusing the previous thread's priming would give Rich the wrong active context.
This adds one priming turn per switch. A report into another thread adds a prime
before the report and another when conversation returns to the original thread.
Sage measured priming at 1.4–1.5 seconds and about $0.084 with initial cache
creation; this is evidence of cost, not a fixed charge for every switch. Reports
also hold the conversation lock for their spoken turn, measured at 5–7 seconds.
The scope correctness is worth those turns; a session per thread would be a
separate resource and lifecycle design, not a silent change here.

This still uses fallible model judgment. Quotes establish provenance, not proof
that a classification is semantically correct. Consistent mistakes remain
possible. The code does not claim mathematical detection of every missed intent.
The detached registrar still costs one inference per answered CEO message,
including discussion. Rich still delegates small actions, so even a small edit
pays registration, independent checks and a worker if needed.

## Failure bounds and retained ownership

Registration attempts and retry deadlines are saved **before** inference. A crash
cannot erase a charged attempt or bypass recovery spacing. Failures wait 30 seconds
for the first three attempts, then one hour. Recovery remains scheduled rather
than abandoning the request or requiring resubmission. This is an ongoing,
rate-limited retry policy, not a finite registration budget. No worker starts from
an invalid registration. A later unresolved instruction fences an older unstarted
request until it can be classified, preventing stale work after cancellation.

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
contract therefore allows at most ten worker attempts and ten verification cycles
per authorization batch, usually fewer because the first cycle checks existing
results. A proposed CEO escalation receives a second read-only challenge within
its verification cycle, so ten cycles can involve more than ten inspector calls. Native
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
The assignment panel lists assignments separately. Controls send the displayed
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

Urban withheld P4 design approval at `63e93ac` (4/10). The original selector-only
contrast assertion was too narrow and the affordance inventory excluded the
panel entirely. Those greens did not establish a usable interface.

The replacement shows portfolio attention counts, a stable assignment chooser
and visible Pause/End controls. Review decision opens a reading surface above
the compact strip. Questions have no individual height cap and answers follow
them in the same flow, with persistent reading controls for overflow. History
is a separate disclosure. Completion checks are 16px with no exemption.
Duplicate titles use dates before a reference is added for remaining collisions. End confirms its exact target. Friendly
errors put Refresh first and retain technical details in history.

Finding 2 required a mechanism, not button styling. `respond_run_decision` now
handles resource continuation, business answers, scope changes and cancellation.
It checks the open conversation, assignment, task and question identity under
the journal lock. The identity hashes the durable question and contract context.
Exact repeated actions are idempotent after restart. Continue grants the displayed
resource allowance only; it cannot answer a business question. Written resource
answers are refused rather than interpreted as spending permission. A business
answer preserves the CEO's exact text and releases only its task. Multiple
pending questions cannot be cleared by an ambiguous conversation answer.

A scope change appends the exact correction to the preserved contract and every
review criterion, superseding conflicting instructions only. It checks existing
effects before more execution. End persists cancellation without claiming
completion. An active writer is interrupted at its boundary before the command
writes; a 30-second timeout remains an explicit failure if it cannot yield.
Saved panel actions get bounded acknowledgments through Rich's normal conversation
and speech path. Canceled assignments no longer publish pending-decision notices.

The new browser tests use the real shell at all five reviewed viewport sizes.
The shared contrast suite now walks seven assignment surfaces in both themes;
it must measure each surface's defining nodes. The affordance inventory derives
all shipped sources and includes short state, label and status maps in each.
Assignment fixtures assert the state text and the usable control together.

Urban's next review of `b45145f` withheld P5 approval at 7/10.
See [the P5 response](URBAN-P5-RESPONSE.md) for the long-question, Rust projection
and source-inventory corrections, evidence and reproduction. The earlier
[P4 response](URBAN-REVIEW-RESPONSE.md) is historical. P5 approval was withheld
until independent re-review. Urban subsequently granted P6 signoff
at `e276ba3`, scoring it 9/10. The [P6 follow-up](URBAN-P6-RESPONSE.md) addresses
the remaining history, contrast-gate and presentation gaps. That document records
the current checks and distinguishes them from Urban's signoff of the earlier
commit. No production deployment or main-branch merge is claimed. Native window chrome, OS accent
behavior and interactive speech were not visually audited in this pass.

Urban kept that 9/10 signoff at `9b6c74d` in P7 after finding no regressions.
The [P7 follow-up](URBAN-P7-RESPONSE.md) addresses the remaining history hierarchy,
action cue and cut-edge measurement findings with current evidence.

See [the main integration record](MERGE-VALIDATION-2026-09-06.md) for merge
resolutions, updater coordination, visible scope corrections and combined testing.

## Review entry points

| Concern | Code |
| --- | --- |
| Conversation entry and voice | `src-tauri/src/main.rs` |
| Detached registration and consistency checks | `crates/richos-core/src/registration.rs` |
| Native tool and permission boundary | `crates/richos-core/src/native.rs` |
| Inbox, discovery, scheduling and report recovery | `src-tauri/src/owned_work.rs` |
| Cycle budget, amendments and independent checks | `crates/richos-core/src/run.rs` |
| Conversation scope and spoken reports | `crates/richos-core/src/spine.rs` |
| Assignment selection and controls | `src-tauri/src/managed_runs.rs`, `src-tauri/src/run_view.rs`, `ui/runs.js` |
| Evidence and reproduction | `managed-run-validation.md` |

The strongest remaining objection is that the host still relies on two models
agreeing correctly about authorization and completion. The durable state machine
prevents silent loss at a turn boundary and bounds recovery costs; it cannot make
those judgments infallible. This revision makes that dependency and its failure
limits explicit instead of hiding them behind a green engine test count.
