# Managed work runs

RichOS owns continuation. A model ending a conversation turn is not evidence
that the requested work is complete.

`richos-core::run` is a portable controller with two hosts:

- The desktop host records separately governed worker attempts through the scoped
  Spine, conversation stream and cancellation channel. Open a bound task, expand **Work plan**, load a prepared
  plan and review it. Preparation does not execute anything. **Start / continue**
  drives the plan. **Pause run** and the existing **Stop** control pause it.
- The `richos-run` terminal binary drives the same controller through the governed
  native model adapter. It works in any explicitly selected workspace. It does
  not attach to, interrupt or rewrite an existing interactive Claude Code team.

This first implementation runs one managed task at a time. Dependencies control
ordering. A failed task does not stop unrelated ready tasks. Parallel worker
allocation is not implemented, and native interactive teams are not a dependency.

## What completion means

A plan is an explicit, finite scope: a goal, workspace, tasks, dependencies,
acceptance commands, attempt limit and per-attempt model timeout. The controller
copies the contract into its journal before running anything. Agent responses
cannot change that contract through the API.

Each task follows `pending -> running -> verifying -> passed`. An `end_turn`
only permits verification. The host executes every acceptance command itself.
A failed check returns the task to `pending` while attempts remain, with the
failure evidence included in the next attempt. Exhaustion becomes
`needs_attention`. Only all tasks passing produces `completed`.

Before declaring completion, the controller rechecks previously passed tasks
against the final workspace. A later change invalidating an earlier result
therefore reopens the affected task. Background shells and model declarations
do not satisfy an acceptance check.

Acceptance is only as good as the checks selected. Commands must test the
requested result and be repeatable without external side effects. A trivial
`true` command or a test weakened by an agent cannot prove a business outcome.
Use separately maintained verification where possible. This controller is not
an adversarial sandbox: a worker with the same OS permissions can modify files,
including verifier code. It does not invent verification for subjective work.

## Failure, pause and recovery

- The journal is flushed before each external attempt and each transition.
  OS file locking prevents two controllers from owning the same journal.
- A model error, refusal, cancellation or timeout becomes `needs_attention`.
  Unknown external effects are not automatically replayed. After inspection,
  an operator may retry within the original attempt budget.
- Missing or moved workspaces do not prevent inspection or cancellation.
  Execution still refuses an unavailable directory. Unreadable journals can be
  explicitly archived in the panel, preserving their bytes for diagnosis.
- Restarting recovers committed state. An interrupted `running` or `verifying`
  attempt is flagged for inspection. A torn final journal append is discarded;
  corrupt committed data is refused. A changed contract in the journal is refused.
- Pausing survives restart. It does not mark tasks complete. An explicit
  **End run without completing it** records cancellation and permits a new plan,
  preserving the old journal. It is not a success state.
- The desktop app must remain open to execute. A machine restart does not
  automatically launch the app or repeat uncertain work. Resume is explicit.
- Verifiers have time and output limits. They must own and clean up any child
  processes they launch; the current verifier adapter terminates its direct child.

Managed workers load user/project/local Claude settings in the selected workspace.
They keep provider transcripts for hooks that read them. The native permission
mode is explicitly `default`; any permission request delivered to RichOS is denied.
Such a denial leaves the run needing attention, even if the model later reports
`end_turn`. There is no automatic grant or fallback to the ordinary chat adapter's
legacy policy. This slice does not include an in-app permission-grant dialog.

Acceptance commands are trusted executable input. The application executes them
under its own OS identity, outside Claude's permission channel. Review their exact
arguments in the panel before Start. Installed settings can authorize tool use;
retaining those settings does not independently certify the installed hooks.

The model adapter must implement cancellation and explicitly support governed
execution in the requested workspace. Desktop attempts use a separate worker
lease and disable automatic crash replay. The original chat lease is restored
and re-primes from the conversation before its next use. User steering remains
between attempts. The run's assistant output uses the `Managed` source and is
rendered live and after reopening; generated task prompts never appear as user
messages. Older binaries need compatibility support to read this new source.

## Terminal use

Build from `app/` with Rust 1.89 or newer:

```sh
cargo build -p richos-core --bin richos-run
target/debug/richos-run create /private/state/work.jsonl /path/to/plan.json
target/debug/richos-run drive /private/state/work.jsonl
target/debug/richos-run status /private/state/work.jsonl
target/debug/richos-run pause /private/state/work.jsonl
target/debug/richos-run resume /private/state/work.jsonl
target/debug/richos-run retry /private/state/work.jsonl implement
target/debug/richos-run end /private/state/work.jsonl
```

`resume` clears a pause; `drive` performs execution. `retry` requeues an inspected
failed task, preserving attempts. `end` requires the writer to be stopped. Exit
0 from `drive` or `status` means completed, 3 means unfinished and 2 means an
operational error. Administrative commands return 0 when their operation succeeds.

Example plan shape, with project-specific checks substituted before use:

```json
{
  "goal": "Implement and verify the requested change",
  "workspace": "/absolute/path/to/project",
  "max_attempts": 3,
  "turn_timeout_seconds": 1800,
  "tasks": [
    {
      "id": "implement",
      "prompt": "Implement the change described in the approved brief.",
      "depends_on": [],
      "checks": [
        {
          "name": "Requested behavior and regression coverage",
          "argv": ["python3", "verification/acceptance.py"],
          "timeout_seconds": 120
        }
      ]
    }
  ]
}
```

This is an interface for prepared plans, not an automatic importer of scattered
Markdown backlogs. A planner must establish scope and meaningful checks. The
desktop stores journals under its application data directory in `runs/`; the
terminal takes an explicit private state path. No runtime state belongs in a
public source repository.

## Migration boundary

Keep concrete safety checks at the actions they protect. Move continuation into
managed runs as work migrates into RichOS. Do not disable all existing guards to
adopt this controller. Existing ordinary chat and interactive terminal sessions
continue to behave as before; neither is silently enrolled in a run.

The implementation is independent of repository names and provider prose. A new
provider implements `Cognition` with cancellation or the narrower `RunHost`
interface. Platform execution belongs to hosts, while dependency ordering,
completion, attempt budgets and journal recovery remain shared.

Verification: `cargo test -p richos-core --test run_tests`, the full core suite,
the desktop build and `app/ui/tests/runs.js`. Tests use controlled model fixtures
and real verifier processes. They do not claim a live production team has been
migrated or that a subjective deliverable has been independently reviewed.

`python3 app/scripts/test-managed-run-mutations.py` removes acceptance gating,
attempt limits, interrupted-work reconciliation, writer locking, visible output,
permission denial, settings retention and workspace-independent recovery in disposable
copies. Each mutation must fail its specific regression test; compiler failures
do not count.
