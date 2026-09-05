# Managed work in RichOS: revised review brief

This branch implements managed work in the RichOS desktop app, with a terminal
adapter for the same controller. The target is RichOS, with repository use as
an additional surface. It is not an in-place repair of an existing interactive
Claude Code team. The earlier review was briefed against that narrower target;
its scope-based rejection does not settle whether this RichOS feature is useful.
Its implementation findings did identify defects, which this revision addresses.

## What “working in RichOS” means here

The surface is a bound desktop task's **Work plan** panel. The user loads a
prepared plan, inspects its workspace, task descriptions, acceptance commands
and attempt limits, then starts it. This is currently an interface for prepared
plans, not a natural-language planner for a nontechnical user.

The controller owns the finite tasks in that plan across model turns. Each
attempt uses a separately governed model worker in the selected workspace. The
worker's output appears in the same desktop conversation, both live and after
reopening it. Its generated prompt is not attributed to the user. The ordinary
chat lease is restored after the attempt and re-primes from the durable record
on its next use, so it can learn the worker's output.

Completion means every required task's acceptance commands passed, with earlier
results checked again against the final workspace. A model's `end_turn` only
starts verification. Failed verification can trigger another attempt within the
plan's budget. Errors, denied permissions, interruption and exhausted budgets
leave work explicitly unfinished. Pause and cancellation are not completion.

This version executes tasks serially. It does not own a parallel worker team,
import Markdown backlogs or attach to a running interactive Claude Code team.
Those are limits of this slice, not reasons to pretend it targets the old guard.

## The problem and the architectural decision

The supplied incident showed a model claiming nothing was unblocked even though
its guard had found free backlog rows. The guard accepted that claim. That is a
real evidence-overridden-by-prose defect, and checking the claim against the rows
in that guard is a valid fix for the incident. The original document's dismissal
of such a change as “another declaration parser” was unjustified.

For RichOS managed work, the design puts task selection, attempt budgets,
verification and recovery in application code. This makes a model ending a turn
an input to a state machine, not the authority that finishes the job. It provides
a shared contract for the desktop and terminal adapters. It does not prove that
guards are inherently incapable of checking substance or that a controller alone
solves planning, subjective acceptance or team ownership.

The controller's host must remain running too. Journaling preserves state; it
does not keep a terminated process alive. There is no installed recovery daemon.

## The Stop-hook citation dispute

Re-fetched on **2026-09-05**, the official
[Stop input reference](https://code.claude.com/docs/en/hooks#stop-input) says:

> Claude Code overrides the hook and ends the turn after 8 consecutive blocks.

The Stop decision-control section also describes the same continuation cap.
The audit's statement that the documentation contains no cap conflicts with the
page retrieved for this revision. This is documentation evidence, not a claim
that the installed binary's behavior was independently measured in this task.

Separately, the existing engine's `guard-idle-land.py` immediately returns 0 on
`stop_hook_active`. That is the engine's own one-refusal choice. It is not the
documented eight-block limit. Neither limit establishes that the specific false
declaration incident requires a new controller. The RichOS architecture should
be reviewed against the ownership and completion contract above.

## Implementation findings and their disposition

| Finding | Change | Regression evidence |
| --- | --- | --- |
| Managed output was `Internal`, which has no durable render path | Added an explicit `Managed` source. Assistant output is public to the bound task; generated user text stays out of conversation and re-prime user attribution. | Real Spine test checks live message events, messages after reopening and equality of timeline projections. |
| The native adapter stripped settings and auto-approved permissions | Managed workers use a separate native launch policy in the actual plan workspace. It loads user/project/local settings, retains provider transcripts for transcript-dependent hooks, forces default permission mode and denies permission requests. Legacy leases are refused by the managed host. | A real subprocess captures its launch arguments, working directory and permission response. Even a subsequent `end_turn` after a denial leaves the run needing attention. |
| A missing workspace made a journal impossible to end | Contract validation is separate from workspace availability. Opening, inspecting and cancelling need only a valid journal. Execution still requires the directory. | Rename the workspace, reopen the journal, refuse execution and persist cancellation. |
| Corrupt journals also trapped the UI | An explicit archive action preserves the raw journal under a unique name and permits a fresh plan. It takes the writer lock and refuses a live owner. | Corrupt bytes survive verbatim; live-writer archival is refused; the UI calls the archive command. |
| README test totals did not match witnessed execution | The revised total is checked against compiled runtime results, not merely a successful shell exit or a source regex. The original audit observed 708 non-doc tests; this revision's measured results are recorded below. | Full cargo output is counted after completion. The source-inventory check is supplementary, not proof that tests ran. |
| File picker and panel violated the type floor | Readable text and controls use 16px at the default scale; supplementary check labels use 14px. | Browser test reads computed styles, including the file-selector button. |

The existing ordinary chat adapter still has its previous auto-approval policy.
This revision does not claim to repair that separate policy globally. Managed
work cannot borrow that legacy adapter or silently fall back to it.

Acceptance commands run directly under the application's OS identity. They do
not go through Claude permissions. A prepared plan is therefore trusted
executable input, and the panel exposes the commands before Start. The worker's
settings are retained, but which hooks and allow rules are installed remains the
operator's configuration. Preserving settings is not proof that every hook is
healthy. There is no in-app permission-grant dialog in this slice; unapproved
requests are denied and the run requires attention.

## Review map

Paths below are relative to `app/`.

| Area | Files |
| --- | --- |
| State machine, journal and recovery | `crates/richos-core/src/run.rs` |
| Model attempt and external verification | `crates/richos-core/src/run_host.rs` |
| Managed native policy and transport | `crates/richos-core/src/native.rs`, `crates/richos-core/src/cognition.rs` |
| Scoped worker and conversation | `crates/richos-core/src/run_spine.rs`, `crates/richos-core/src/spine.rs` |
| Durable attribution and rendering | `crates/richos-core/src/ledger.rs`, `crates/richos-core/src/timeline.rs`, `crates/richos-core/src/reprime.rs` |
| Desktop commands and controls | `src-tauri/src/managed_runs.rs`, `ui/runs.js`, `ui/style.css` |
| Terminal adapter | `crates/richos-core/src/bin/richos-run.rs` |
| Regression and mutation checks | `crates/richos-core/tests/run_tests.rs`, `ui/tests/runs.js`, `scripts/test-managed-run-mutations.py` |

## Validation

See [managed-run-validation.md](managed-run-validation.md) for the completed
commands and measured totals for this revision. Tests use controlled model
fixtures and actual subprocess transport and verifier execution. They do not
claim a live production team has migrated or that a real Claude deployment has
been acceptance-tested end to end.

Eight mutations remove acceptance gating, attempt limits, interruption recovery,
writer locking, visible managed output, permission denial, settings retention
and workspace-independent recovery. Each must fail its named regression test;
compilation errors and zero-test runs do not count as detection.

## Deployment and remaining limits

This branch is isolated and unmerged. It changes no installed hooks, active team
session or other agent's branch. The existing guard fix remains a separate review.
An exploratory guard alternative was set aside when the review target was
clarified; it is not part of this proposal.

A safe first trial is a bounded RichOS task with independently maintained checks.
Inspect the output and journal, exercise pause and process interruption, then
assess whether its acceptance actually proves the requested result. Larger team
ownership and planning need their own concrete contracts before being claimed.

The journal does not guarantee exactly-once external effects. Verifiers kill
their direct child on timeout and must clean up their own descendants. Workers
with the same OS permissions can alter verifier files, so this is not an
adversarial verification boundary. Subjective work needs an appropriate reviewer
or acceptance mechanism; a convenient shell exit code cannot establish quality.

The new `Managed` source is a conversation-ledger format addition. An older
binary that does not recognize it cannot read a ledger containing those turns.
Do not treat a source revert as a lossless downgrade after live use. Trial data
should be isolated or backed up first, and a downgrade reader would need explicit
compatibility support. Managed provider transcripts also now persist in Claude's
normal private data directory so transcript-dependent hooks can work.
