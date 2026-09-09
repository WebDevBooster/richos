# Revision 5: native delegation and restart recovery

This revision addresses the activation conditions in Sage's external R4 review of
`e0679a55`. That review accepted the foundation for merge but identified three
native defects: discarded operational briefs, whole-conversation fan-out and no
pickup after starting a fresh Claude session. The original assignment also requires
a composed behavioral test with interrupted work and restart recovery.

Implemented and verified on `codex/owned-outcome-completion` in its separate
worktree. Historical R4 evidence is unchanged. [RESULTS-5.md](RESULTS-5.md) records
the real trials, failed predecessors, exact tested versions and activation steps.
This is a review handoff; production has not been activated.

## Scope

- C1: preserve Rich's operational brief beneath the registered authority.
- C2: bound each teammate's prompt without truncating constraints.
- C3: recover unfinished native work after restart with exclusive ownership.
- C4: verify sidecar generation and document the required installation at land.
- C5: describe the existing permission policy accurately; no policy change here.
- C6: restore deterministic pending/revocation coverage and remove the two
  confirmed dead assignments/constants.
- F8: run the composed native assignment through an interrupted worker and both
  fresh-session pickup and same-session resume, with no resubmission or nudge.

Unrelated improvements remain in IMPROVEMENTS.md. This revision does not add a
background operating-system service, transfer work into RichOS from another
surface or promise perfect model interpretation of arbitrary prose.

## Delegation contract

The registered brief remains the authoritative scope and must preserve applicable
CEO constraints. The lead's operational brief supplies the specific worktree,
reproduction steps, file references and instructions for that teammate. It cannot
grant new authority or select another registered assignment. A different work
selector embedded in that brief is rejected.

Each spawn carries the complete registered brief, its verified citation excerpts
and the complete subordinate operational brief. It does not carry all messages
from the session. The total UTF-8 envelope is limited to 32 KiB. An oversized
envelope is refused intact with recovery guidance; it is never silently truncated.
The original source remains in the host ledger for review. Registered scope plus
citations has a separate 16 KiB budget. An oversized cached record is repaired
through the existing source-bound registrar, which must compact or split the work
without dropping constraints. Invalid oversized results are not published and
retain the normal retry pacing. A long lead brief instead gets explicit shortening
guidance. Neither case is reported as missing CEO authority.

This is a bound on dispatch payloads. Registration still interprets the full
retained source when verified human authority changes. It is not a claim that all
model inputs are bounded to 32 KiB. Semantic completeness of the registered brief
still depends on the registrar; membership of a citation cannot prove that no
constraint was omitted.

## Native lifecycle contract

An assignment survives the process that accepted it. A replacement session must
recover the original authority and unfinished obligations while preserving later
restrictions. Recovery must not manufacture a new human message or copy permission
grants into another native invocation.

Pickup is exclusive to the canonical workspace. A live original leader retains
ownership. A dead leader's unfinished work can be claimed by a replacement; old
hooks and competing claimants must not continue that work afterward. Ownership
publication must survive interruption between journal writes. Completed work must
not be replayed merely because a new session starts.

The adapter uses the existing synchronous SessionStart capture and
`asyncRewake` audit hooks. Claude documents that an asyncRewake hook exiting 2 can
wake an idle session; that contract does not substitute for a measured restart
trial. See the [official hook reference](https://code.claude.com/docs/en/hooks#run-hooks-in-the-background).

Ownership is stored outside the checkout with the canonical workspace, native
session ID and observed process PID/start identity. A pending transfer is saved
before target state publication, so an interrupted transfer can finish atomically.
Original sources keep their provenance and session attribution. Late-flushed
restrictions are refreshed before reconciliation. Native permission grants are
not transferred; refusal and unknown-effect history remain restrictions. New Agent
dispatch and SendMessage resumption both wait for startup reconciliation. A pending
human instruction also fences teammate resumption until its source is corroborated.

A superseded leader cannot run tools or generate another continuation wake. An
explicit later SessionStart can reclaim a dead successor, including returning to
the original history after a fresh-session pickup. A live successor retains its
work. Inspection counters and deadlines survive restart rather than buying a new
burst of model calls. Consumed worker-completion checkpoints survive too.

Legacy ledgers without process ownership are recovered only when the native
process registry can account for live Claude processes. Unknown ownership is
retained for later reconciliation, not treated as proof of a dead leader. Recovery
requires Claude to start in that workspace; no service is installed to run while
all native sessions are closed.

## Final verification after worker completion

A real restart trial exposed an additional scheduling defect: inspections while
workers were active used the normal allowance, then the final inspection waited
an hour even after engineering and review finished. The controller now recognizes
an additional completion checkpoint from native execution evidence.

It follows linked Agent and SendMessage invocations through nested children,
requires actual successful work receipts and waits for the relevant invocations
to finish. Native terminal metadata is evidence that a worker stopped, not proof
that the assignment is complete. The independent auditor still checks the result.
A lead's completion claim or a notification-looking string in a worker report
cannot supply that checkpoint.

At a leader Stop after the normal burst is exhausted, an eligible previously
unconsumed completed batch can bypass the saved delay for one inspection. That
checkpoint is recorded before the model call. The consumed invocation IDs survive
ownership transfer and restart. Repeating a
notification, changing assistant prose or restarting does not refill the ordinary
retry allowance. A later batch of actual executed work can earn another check.
This preserves responsiveness after real work, while the existing pacing remains
for repeated incomplete or failed inspections without new eligible work.

This is not a fixed ceiling on all model calls: completed workers that execute
useless work can still create new execution evidence. Detecting semantic progress
in such work is separate from proving that a native invocation ran and finished.
That limitation is recorded in IMPROVEMENTS.md.

## Model calls and permissions

The existing native permission policy first refuses an unapproved operation so
Claude can try an already permitted alternative. A repeated request with necessity
evidence gets a separate review before the native permission prompt can stand.
The adapter never grants that permission. The other installer option, `deny`,
refuses every new permission request; it is not a passthrough option.

Desktop discussion receipts avoid registration calls. Native Stop audits can run
at the end of each changed turn, in addition to changed-source registration,
question validation and eligible permission-necessity reviews. “Not every turn”
must not be used as a blanket native cost claim.

Claude can draw a permission dialog before the hook returns. Routine recovery can
therefore clear a briefly visible prompt without an answer. That documented R4
limit remains. An assignment completion claim needs observed outcomes, not an
inference from the existence of guards.

## Acceptance discipline

Freeze production source, harness and executable before a real trial. Run each
scenario once for that implementation. Preserve the original requests, process
interruption receipts, both transcript histories, input events, model results and
delivered artifacts. A failed trial is retained. Another paid trial requires a
concrete correction, not a desire for a different model answer.

The composed fixture includes a stale backlog, an obsolete assertion, a real code
defect, an unrelated unresolved CEO decision and required engineering plus review.
Interrupt an actual working child and its disposable leader. Restart without
sending the original request again. Require restored coverage, actual test and
parser execution, unchanged requirements and independent verification. Measure
ordinary prose questions separately from structured questions and permission UI.

## Installation at land

From the stable landed RichOS checkout, run:

```sh
bash engine/scripts/hooks/install.sh
```

This refreshes the gitignored content-hash sidecars, including the three owned-work
libraries. The branch also contains the earlier guard timeout change from 20 to
240 seconds. The unadopted guard still exits through its existing policy path.
The installer can update the engine pointer and reconciler registration in a real
installation, so the verification here runs it in a disposable engine copy with
isolated configuration and checks that the production pointer is unchanged.

Workspace adoption remains a separate explicit step using the rebuilt runner and
stable checkout:

```sh
python3 engine/scripts/install-owned-work.py /absolute/workspace /absolute/richos-run --permission-policy native
```

Inspect the settings change and run the engine integrity probe in the intended
workspace. In femcboost, `settings.local.json` is tracked and adoption must not be
treated as an invisible local-only modification. Resume the intended existing
session when initially adopting its current assignment so source capture records
that history. Fresh-session pickup recovers recorded obligations; it does not
invent an assignment by searching every previously unmanaged transcript.

Neither production adoption nor a production install is performed by the tests.
No permanent hook should point at this disposable development worktree.
