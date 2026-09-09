# Revision 7: checker ownership through crash and delivery

This revision addresses [Sage's R6 review](evidence-r7/review-r6.md) of
`125906f5`. Earlier corrections made restart reconciliation immediate and
withheld work visible. The remaining failure was a surviving checker from the
dead session consuming the replacement's check and sending its wake to a dead
parent. The prior process fixture did not leave that detached checker alive.

The implementation remains in the separate `codex/owned-outcome-completion`
worktree. [RESULTS-7.md](RESULTS-7.md) records verification and source identities.
Earlier reports and their original results remain unchanged.

## Scope

- C10: bind each checker to its actual native process, fence stale checkers
  throughout waiting and publication, and preserve the replacement's callback
  when the old checker temporarily holds its lock.
- C11: exercise real native fresh-session and same-ID recovery after a
  leader-only crash while a detached Stop checker is sleeping in the hour regime.
- R6 F3: tolerate transient process-table failures during mechanical waiting.
- R6 F4: recover an interrupted inspection without overlapping a surviving
  inspector or refilling the ordinary inspection allowance.

The same-ID observer's restricted tools, native permission policy and optional
compatibility work remain separate. No new operating-system service or blanket
process-kill authority is introduced.

## A checker keeps its original identity

Session ID alone cannot identify a checker. A resumed session reuses that ID
while a detached checker from the previous process may still be alive. The
checker therefore captures its actual native ancestor identity and retains that
binding. It cannot adopt a replacement's identity by rereading the shared state.

The binding is checked before work, while waiting, before reserving an inspection,
before publishing a result and before sending a wake. A dead or superseded
checker retires without consuming the replacement's ticket or publishing into
its state. An unavailable process table is distinguished from positive evidence
that the original owner is gone.

The replacement can wait for a temporarily held audit lock when it has a pending
recovery check or undelivered host notice. Lock contention must not turn a required
startup callback into a successful empty exit. The wait is bounded and preserves
continuation rather than granting another inspection allowance.

Pending callbacks wait up to 30 seconds for the audit lock. An inherited
inspector lease can be waited on for up to 300 seconds, with ownership checked
throughout. Transient process observation failures get three attempts separated
by 0.2 seconds. Exhausting those attempts produces a recovery diagnostic and
keeps the work unfinished.

## Inspection and delivery have separate completion records

An inspection has a persisted attempt identity, owner binding and lifecycle.
The actual runner inherits a separate inference-lock file descriptor. If the
hook dies while that runner survives, the runner retains the lease and another
hook waits instead of launching a duplicate inspection. Once the lease is free,
a demonstrably interrupted attempt can receive one immediate retry. Ordinary
counters remain intact.

Duplicate captures and ordinary assistant chatter do not replenish that retry.
A second interruption remains subject to ordinary pacing. Successful verdict
publication ends the interrupted-attempt chain.

Publishing a verdict is also distinct from delivering its continuation to the
native leader. An owner-bound pending wake is retained until the CLI flushes
its actual output. A later valid callback can deliver an unsent wake without
buying another inspection. A crash between output and acknowledgment can cause
duplicate delivery; such a wake carries no new authority and does not refill
inspection credit.

The pending wake is also bound to the current instructions, execution evidence
and withheld work. A correction or cancellation supersedes stale output. The
last context check, output flush and acknowledgment share the state lock.

## The leader must receive useful inspection findings

The first real fresh-session crash trial recovered correctly but did not finish
within its actual 20-minute execution ceiling. Its inspectors identified missing
engineering and final review steps. The continuation renderer discarded those
findings and sent a generic instruction to continue. That is evidence of lost
feedback, not evidence that the leader ignored a correction it received.

The correction delivers a successfully validated incomplete report as a separate
JSON diagnostic envelope, bound to its original audited inputs and native owner.
The host directs the leader to check those findings against the original request,
current artifacts and execution receipts. Inspector claims about tools or
permissions do not become worker policy or new CEO authority. Provider exceptions
and rejected decision proposals remain outside this report.

A changed request, execution evidence or owner suppresses the old report. This
change does not refill inspection allowances or add a repeated reminder loop.
It also does not promise that quoted diagnostic data cannot influence model
prose. Native permission enforcement and source validation remain in force.

## A resumed agent needs a generation-specific completion receipt

The next real same-ID trial delivered the findings and completed the engineering
and review work. Final inspection still stalled because Claude reported the old
agent as stopped, resumed that same agent and later delivered a completion notice
without a tool-use ID. The parser ignored the stopped state and treated the two
invocations as an unresolved ambiguity.

The narrow correction retires an authoritatively stopped invocation without
counting it as successful work. A later successful native resume can use a
completion notice without a tool-use ID only with additional generation evidence:
its full result uniquely matches actual child assistant output after that resume
and does not repeat an earlier generation's output. Existing execution-receipt
and nested-completion requirements still apply. Ambiguous or delayed old output
must not create inspection credit. The input meter independently recognizes this
same native carrier instead of misclassifying it as a new human instruction.

## Verification against the host

The mechanical fixture runs hook CLIs in separate process groups, retains the
old sleeping hook after killing only its leader and records which actual hook
called the inspector. Same-ID recovery proves shared-lock handoff; fresh recovery
uses its own session lock and proves the old hook cannot act on the replacement.
A separate hook-only interruption case leaves its inspector alive to test the
inherited lease. The actual Rust runner's FD retention is independently checked
with scripted native transport.

The real-provider crash scenario uses the original composed assignment. After
real guarded child work starts, the harness explicitly seeds only the pacing
state into the exhausted regime and records the before/after values. It does
not claim five paid inspections occurred before the crash. It then requires an
actual sleeping Stop audit, records its process layout and kills only the
recorded native leader PID. Survivors are retained through recovery, not cleaned
up as part of crash injection.

One final resume fixture adds an opt-in scheduling/interruption hook because the
prior run finished before a natural crash window appeared. After an actual
source-linked child Read, it holds that original child's next tool for at most
180 seconds. It matches the original leader's exact process identity, claims
once and cannot hold a replacement. The separate synchronous command hook has
an explicit 240-second timeout; existing product hooks and permission settings
are preserved. Claude's [hook reference](https://code.claude.com/docs/en/hooks#timeouts)
documents the timeout behavior. This is disposable test instrumentation.

On original leader death or the fixture deadline, the hook exits 2 and aborts
that held tool. This is an injected interruption of one original tool, not just
a delay. The fixture still requires a naturally occurring sleeping Stop audit
before killing only the leader PID. No Stop event, model prompt or permission
approval is manufactured. A timeout without that Stop is a failed fixture.

The replacement receives no assignment or operational nudge. Verification checks
its startup wake, inspector provenance, first allowed Agent dispatch and eventual
independent completion. Cleanup afterward is limited to the fixture's recorded
processes. Exact results, failures and limitations belong in RESULTS-7.md; a
passing scripted fixture is not a substitute for a live native crash trial.

## Installation and remaining limits

This worktree is a review handoff. Production installation and adoption are not
part of its tests. At land, run `bash engine/scripts/hooks/install.sh` from the
stable checkout to refresh the changed library's sidecar, then perform explicit
workspace adoption as described in [REVISION-5.md](REVISION-5.md#installation-at-land).
Permanent hooks must not point at this disposable worktree.

Native ordinary prose still has no universal zero-trivial-question guarantee.
The same-ID recovery observer retains its existing read-only restriction while
the old group can act. Additional process-management authority and compatibility
enforcement remain recorded in [IMPROVEMENTS.md](IMPROVEMENTS.md).
