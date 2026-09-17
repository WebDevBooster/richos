# Desktop work and authority contracts

The app's selected engine supplies a generic worker and reviewer, the work MCP
adapter and canonical Mega Lander controls. The provider starts in private app
coordination. Target repositories must be explicitly connected to the active
company. Company folder mappings alone confer no execution grant.

Workspace registries and target-worktree directories are partitioned by company and thread before provider
startup. Provider sessions share a partition only when they serve the same
thread. User instructions are attested from an exact ledger text digest; hidden
priming and provider-authored prompts never become user instructions.

## Dispatch and recovery

`richos_work.prepare` requires an open ECS obligation and the current visible
user turn. It records an intent before creating a target worktree through the
canonical spawn preparer. The exact returned Agent payload is submitted once.
A hook joins the receipt to the actual provider tool call, then canonical
lifecycle callbacks supply the real agent ID. An uncertain attempt is inspected,
not automatically dispatched again under its old key.

The worker receives a host-verified target. Direct writes outside that target,
including symlink escapes, are refused. Shell actions retain native permission
decisions; a path check is not represented as an OS sandbox. The profile excludes
terminal-wide Git configuration and uses a generic local RichOS commit identity.
It does not import an operator's terminal hooks, staff or private knowledge.

Receipt states distinguish preparing, prepared, dispatching, running, run-ended,
interrupted, unknown and integrated. A run ending does not establish success.
ECS observations use durable outboxes so a crash after the ECS commit but before
the local receipt can reconcile without a duplicate event.

## Continuation

A new worker can name `continue_of` after the original execution settles. The
adapter derives the base from the actual saved commit. Dirty files are retained
and refused before workspace creation; Rich must inspect and reconcile the
intended changes through the normal permission path. The adapter never resets,
discards or silently commits them. Canonical continuation records the original
session's exact workspace key and requires a fresh review of the revised result.

The delivered desktop execution contract joins the app's standing instruction.
Users describe their assignment; Rich owns internal obligation and receipt IDs.
Saved work summaries are available in the conversation, with observed run ends,
review verdicts and local integration kept distinct from whole-task completion.

Provider messages with a non-null `parent_tool_use_id` belong to a worker. Their
reports retain that attribution in the work journal and never become the lead's
conversation text. Nested worker results cannot end the lead turn or reset its
streaming state. Permission control messages still use the normal decision path.

## Review, integration and cleanup

A reviewer names a worker receipt. Its worktree is based on the worker's actual
clean commit. The host captures a typed verdict from that reviewer's observed
SubagentStop callback, including the exact commit and provider identity. On providers
that deliver the report through `SubagentHandback`, the host records only a successful
PostToolUse delivery from that same reviewer. A later observed SubagentStop must
settle the run before that report can authorize integration. Attempts, failed
handbacks, wrong identities and mismatched commits never establish a passing review.
An explicit malformed final verdict cannot fall back to an older passing handback.

`richos_work.integrate` requires that passing verdict, unchanged worker/reviewer
commits and clean checkouts. It persists an integration intent before a local
fast-forward. It does not push, rebase, resolve conflicts or overwrite unrelated
edits. Recovery checks Git before retrying. Mega Lander owns cleanup, with partial
cleanup reported separately from a verified integration. An explicit retry uses
the canonical deletion path and rechecks eligibility; an earlier landing receipt
does not certify that resource deletion completed.

A verified work result is not completion of every condition in a broader
obligation. The adapter does not close the entire obligation automatically.
Completed work and authority receipts remain inspectable with `include_closed`.

## Background assignments

Work the CEO asks for runs on a **second compute lease** in the same process, owned by a
work host that is not the spine. The conversation's lease is held for a whole turn, so work
leaves the turn only by leaving that lease.

A conversation turn ends when the assignment is **registered**, not when it settles.
`richos_assignments.record` is app-owned, writes one durable record and returns the sentence
to say; `richos_work.prepare` and everything it costs run afterwards, on the work lease. A
failed registration is reported as a failed registration and is never softened into a claim
that work started.

The register holds what he asked for in his own terms, the obligation it carries out, and
the ledger reference and digest of the turn he gave it in, frozen for its life. Each open
assignment has one ECS seat, spelled from its obligation, bound with a worker audience and
released with the assignment; a second open assignment on one obligation is refused, because
one seat shared by two is the collision the seat exists to prevent.

His next message never cancels an assignment, and Stop stays the conversation's Stop. Each
assignment carries its own stop control where the work is visible. The work lease is never
attached to the conversation's turn control, so a conversation Stop cannot reach it, and
quit stops it by name.

A result reaches him as a durable notice held on its assignment until he has been told, so a
result that lands while he is away is found when he returns; it is also pushed while he is
present. A notice arriving during a turn or a spoken exchange waits for the boundary.

An assignment's workers all ending does not settle it. Settled is read from the obligation.
An assignment whose workers have ended while its obligation is open has run to the step that
would change his repository and stopped there, because local integration is not on the list
of actions a worker may take without asking — so what he is told is that it is ready for him
to approve, never that it is done.

Each conversation thread holds one front desk and one back end. The conversation talks to the
CEO and relays; that thread's standing back-end lease starts and stops jobs, dispatches, lands
and keeps the record, and it is never visible to him. It is opened on the thread's first
assignment and every assignment on that thread afterwards runs on it, however many there are.
A second conversation gets its own back end and the two run at the same time, so neither
waits for the other. A back end is renewed when it has consumed enough of its context window
to be near its limit, and only between assignments, never inside one: a fresh connection is
opened first, told what is still open from the record and what the outgoing one says it was
in the middle of, and only then takes over. An assignment open across a renewal keeps its
record, its seat and its approval line. An assignment is a bookkeeping unit inside a back end — its own record,
seat, stop and approval line — and not a second mind.

The front desk gets no orchestration tools. It relays: it writes an assignment down and it
reports what the record says. A work tool asked for on a conversation's own binding is
refused at the permission desk as well as absent from what that lease was given, so drifting
into doing the work takes two mistakes rather than one. Its standing instruction is its own
job rather than the back end's execution contract, so it is not told to do what it can no
longer do.

It has one read of its own, and it needs one: with the work tools gone, every other status
surface in this app is a command reaching the window rather than a tool reaching Rich.
`richos_status.background_work` is app-owned and read-only, answers what is running, what is
waiting for him and what finished for **that conversation only**, from the record on disk,
and calls nothing. It cannot start, stop, approve or retry anything — those are the controls
on the assignment, or they are relayed — and it returns his own words rather than any
identifier. A permission request waiting in the running process is not in its answer; the
durable half of the same fact is, as the assignment that stopped at a step of his.

Each conversation's front desk stays resident. Switching conversations parks it alive with
its own provider session, its own priming and its own context measurement, rather than
killing it and rebuilding a new one from the ledger, so a conversation he returns to is the
one he left. The app holds a bounded number of these open at once; past that, the least
recently spoken one is retired and its next turn starts a fresh desk, which is what every
conversation did before residency. A message to any conversation is accepted and answered on
that conversation — never refused because he had moved — and one sent while another
conversation is mid-reply is durable immediately and answered at that reply's boundary.

Each conversation binds the CEO's cursor on its own seat, `ceo-thread:<thread_id>`, derived
the same way by the app and by the engine and asked for through the engine's own capability
answer rather than assumed; an engine without it binds the single legacy cursor. That is what
lets two conversations hold turns open, checkpoint and read their briefs without disturbing
each other.

**The limit, stated rather than implied: a conversation's reply may wait behind another
conversation's reply — seconds — but never behind work.** Work runs on its own lease, one per
conversation, and takes no part in the conversation's lock. Measured with
`cargo run -p richos-core --example conversation_wait_behind_another --release`: a message
sent one second into a scripted three-second reply on another conversation was answered
2.028 s later, of which 1.996 s was the remainder of that reply and **25–32 ms** across four
runs was the app's own share.

A request for an action that is not on that list waits for him rather than being refused for
want of a visible turn. The permission desk holds one ordered queue for both leases: the
head of the conversation's requests is shown on the permission sheet, and background work's
are shown on the assignment they belong to, with the approve and decline controls beside the
sentence that says the decision is his. A background request is held by the ASSIGNMENT's
identity rather than by a turn, so it survives the work lease's turn ending, and it is
released when that assignment settles, fails, is stopped, or is open at quit. A queued
request blocks only its own worker.

The provider call that raised a request still ends at its deadline, in "not approved" and
never in approval. The request does not end with it: the receipt says which step it is
waiting on, and his later answer applies to the assignment. Approved, the assignment goes
back on the work lease to take the step he approved — one exact action, one exact input, once
— and the run that resumes has no standing permission for anything else. Declined, it stops
where it stands with nothing in his repository changed and everything it produced kept.
Nothing is ever approved on his behalf, and nothing restarts by itself: a resume happens
because he pressed approve.

The queue lives in the running process. An assignment that stopped at a decision of his
before a restart is still recorded as waiting, and the surface says so and points at the
conversation rather than at a control that is not there; carrying the question itself across
a restart is not built.

At launch, every assignment still open is reconciled — against the work connection's own
evidence and against Git, never against a clock. Work that was running is reported as
unknown until something witnesses it again: not finished, not stopped, and never silently
resumed. What was established is said plainly, including that his repository is where it
was, or that it has moved and nothing can be attributed to this assignment. An assignment
that had already stopped at a decision of his is left as it stands, because that was
recorded while the app was watching. Nothing restarts by itself: picking work back up is his
decision. Standing action grants left open by a crash are closed in the same sweep, and work
seats with no assignment behind them are released — his own seat is identified positively
and never touched, and a seat that cannot be released is reported rather than skipped.

The update gate reads both leases. An update is declined while an assignment is running, while
an assignment is waiting for his approval, and while the assignment register cannot be read at
all; the offer stays available, and the reason says which of those it is. Nothing registered
and no work lease is a clear answer rather than a refusal, so an app that has done no
background work updates exactly as it did before.

Closing the last window no longer ends the process while work is registered. The work keeps
running, the app stays in the Dock with no window, and clicking the Dock icon brings the
window back. With nothing registered, closing the last window quits exactly as it always
has. When the last registered assignment ends with no window open, the app closes itself: an
assignment waiting for his approval has not ended, so that one keeps it up — it is holding
his answer, and the alternatives are to throw the work away or to land it without asking.

Quit still stops the work, and says so first. Choosing Quit with something running names
what is running and offers two answers: quit and stop it, or keep working. Stopped that way,
an assignment's receipt reads interrupted and everything it produced is kept. A force quit,
a logout and a power cut have no such seam; what he is told about those is on the next
launch, below.

## Lifecycle

The first desktop policy settles owned workers on Stop, scope change and quit.
A process supervisor also observes desktop parent death, so teardown does not
rely solely on Rust destructors running. Its live group leader reserves the
process identity until teardown. The supervisor does not restart work.

Workers must settle before the reasoning turn ends. If a provider returns while
workers remain open, the host stops its owned processes and retains workspaces
and receipts for reconciliation. Work registered with the CEO continues while the
window is closed, on the process that started it; nothing survives quit, a force
quit or a logout, and no persistent job is created for it.
Recovery never converts interrupted execution into verified completion.

A lease working outside the visible turn names its own ECS seat on every request,
one seat per assignment, so its frozen binding survives whatever is said in the
conversation meanwhile. Seats are reconciled in the same sweep as receipts: a
seat whose assignment is settled or absent is released, a seat whose assignment
is merely waiting for a decision is kept, and a seat that could not be released
is reported rather than skipped. An assignment whose workers have all stopped is
not settled -- that is the state where it is waiting for approval.

## Knowledge corrections

Operational changes use ECS checkpoint/update contracts. Knowledge changes use
the existing Loro proposal and confirmation desk. ECS never becomes a second
knowledge writer. It projects confirmed desk writer outcomes as verified
historical receipts, with scoped idempotent recovery. An unknown writer outcome
is held for reconciliation and cannot become an unanswered proposal on restart.
A bounded receipt summary accompanies rehydration; omitted receipts are available
through scoped inspection.

The native hook interface supports host context at tool boundaries. See the
[provider hooks reference](https://code.claude.com/docs/en/hooks). Actual behavior
is also exercised by the opt-in live desktop probe.
