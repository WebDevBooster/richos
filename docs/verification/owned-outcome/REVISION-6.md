# Revision 6: immediate restart reconciliation and visible withheld recovery

This revision follows [Sage's R5 review](evidence-r6/review-r5.md) of `d8afbc1f`. That review accepted the
delegation and context fixes but left native activation blocked by two restart
failures: an inherited inspection deadline could prevent dispatch for an hour,
and surviving processes could silently prevent assignment pickup.

The changes remain in the separate `codex/owned-outcome-completion` worktree.
[RESULTS-6.md](RESULTS-6.md) records verification and the exact source identity.
Earlier results and failed trials remain unchanged. This revision does not merge,
install into production or adopt an actual workspace.

## Immediate reconciliation after a real transfer

Ordinary inspection counters, failure counts and retry deadlines still survive
restart. Clearing those on every startup would make a restart loop refill the
inspection allowance. Instead, an actual ownership/process transition with
unfinished work creates a durable reconciliation ticket.

The replacement can use that ticket for one immediate independent inspection,
even when the inherited deadline is an hour away. The ticket is consumed before
the inspector is called. Repeated startup hooks for the same process cannot
create another ticket; a failed call cannot reuse its ticket. A later actual
process death and ownership transition can create a new one. This applies to
both a fresh session and a new process resuming the same session ID.

The inspection still reconciles the retained source and observed effects before
teammates resume. A ticket does not declare completion, change the assignment,
grant tools or turn recovered instructions into a new CEO message. The existing
worker-completion checkpoint serves a separate purpose and remains intact.

## Recovery withheld by a surviving process

A replacement must not act on work that another live owner or surviving member
of its dedicated process group can still perform. The ownership fence remains.
The adapter now records why unfinished work is withheld and the observed blocking
process identities, and includes that information in both startup context and
the hook's visible system message.

An otherwise empty replacement session also needs to start investigating. The
existing asynchronous audit hook therefore emits a bounded host notice that
wakes the leader without calling an inspector. Repeated unchanged notices do not
create a stream of wakes or paid inspections.

Rich is instructed to inspect the exact current process identities and effects,
preserve genuinely active work and use normal permitted tools for safe recovery.
The adapter does not kill processes or authorize a blanket process-group kill.
The engine's worktree liveness helper is useful additional evidence about an
isolated agent; it does not replace native process identity checks.

Subsequent leader Stop hooks recheck withheld work. The existing asynchronous
audit hook also watches process liveness without calling a model, so a blocker
that exits after the diagnostic turn can still be noticed. Once the blocking
processes are gone, the same replacement can claim the assignment and use its
immediate reconciliation ticket. No second session or CEO resubmission is
required. This uses the existing native session lifecycle; it does not install
an OS service.

The watch fits within the existing hook timeout. If processes remain at its
hourly boundary, a durably paced host continuation renews diagnosis through the
native lifecycle. Repeated hooks cannot refill that reminder window. Watching
and these host notices do not call the outcome inspector.

Resuming the same session ID while its old process group survives requires an
additional distinction. The replacement is a recovery observer, not the work's
new owner. It can inspect through permitted read-only tools while assignment
execution and teammate resumption remain fenced. The old process identity is
retained until pickup is safe. A genuinely live original leader cannot be
replaced by this observer path.

This observer allows `Read`, `Glob` and `Grep`, subject to normal native
permissions. It cannot use Bash to terminate a non-terminating residual process.
Its notice states that limit; the mechanical watcher can recover after that
process exits. A fresh-session replacement retains the normal permitted
diagnostic tools. Adding a narrowly authorized process-management capability to
the same-ID observer is separate work, not an implied permission grant here.

## Small corrections from the same review

Legacy process-start comparison parses the two observed date layouts instead of
comparing locale-dependent strings. Malformed or mismatched start times do not
establish ownership.

Dispatch brief correction now has its own diagnostic disposition,
`brief_correction`. A source-verification failure remains `unverified`.
Trailing prose punctuation around an embedded reference to the same assignment
is accepted. The first-line selector stays exact and a different assignment ID
remains refused. Operational instructions remain byte-identical.

Native adoption requires an actual ancestor whose executable basename is
`claude`. An npm installation visible only as `node` is unsupported by this
adapter. The transport has been measured on Claude Code 2.1.263 and 2.1.266;
this does not establish compatibility with all versions. Installer enforcement
and additional runtime support remain separately recorded in
[IMPROVEMENTS.md](IMPROVEMENTS.md).

## Installation and limits

After landing into the stable checkout, run
`bash engine/scripts/hooks/install.sh` to refresh both changed library sidecars.
The disposable installer check here verifies that operation without changing the
production engine pointer or loading a launchd job. Workspace adoption remains
the explicit step described in [REVISION-5.md](REVISION-5.md#installation-at-land).
Permanent hooks must not point to this development worktree.

The R6 process fixture tests actual host hooks and OS process identities with a
scripted leader and inspector. It does not demonstrate a live model choosing to
resolve every possible straggler. Historical R5 real-provider trials retain their
own source versions and must not be relabeled as R6 trials. Native free-form prose
still has no universal zero-trivial-question guarantee. Optional improvements
remain outside this revision.
