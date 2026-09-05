# Managed work runs

RichOS owns continuation. A model ending a conversation turn is not evidence
that the requested work is complete.

`richos-core::run` is a portable controller with two hosts:

- The desktop host uses the existing scoped Spine, conversation stream and
  cancellation channel. Open a bound task, expand **Work plan**, load a prepared
  plan and review it. Preparation does not execute anything. **Start / continue**
  drives the plan. **Pause run** and the existing **Stop** control pause it.
- The `richos-run` terminal binary drives the same controller through the existing
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

The model adapter must implement cancellation. An adapter without it is refused
before an attempt, rather than silently ignoring the timeout. Desktop attempts
disable the Spine's automatic crash replay because the run controller owns that
decision. Existing user steering and context rotation remain between attempts.

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
attempt limits, interrupted-work reconciliation and writer locking in disposable
copies. Each mutation must fail its specific regression test; compiler failures
do not count.
