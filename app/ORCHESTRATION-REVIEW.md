# Durable orchestration: problem, design and review guide

This change moves responsibility for continuing work out of the model and into
a persistent RichOS controller. It is an implementation for review, not a claim
that existing interactive agent teams have been migrated or repaired in place.

## The problem

An orchestrator can finish a conversational turn while the work it was meant to
coordinate is still unfinished. The operator then has to notice the silence and
ask it to continue. Adding more instructions to keep working has not removed
that dependency on the operator.

The supplied session showed a concrete instance: the stop guard found four
actionable backlog rows but accepted a `stop-declared: nothing-unblocked`
declaration. The declaration's form and explanation length satisfied the guard;
the claim was not established against the work state. The operator subsequently
asked why no work was happening.

The inspected guard also had other paths that could allow a stop: a repeated
Stop invocation, a turn without a recognized completion event and tool activity
classified as dispatch without evidence that it advanced the outstanding work.
Backlog discovery depended on file and text conventions. These are distinct
ways for conversation heuristics to diverge from actual execution state.

The private transcript, personal paths and backlog contents are deliberately
excluded from this public review document. The reproduction tests below capture
the failure mechanism without that private material.

## Are guards the right architecture?

Guards remain useful for checking concrete actions. A stop guard can also catch
some accidental early exits. It does not provide durable ownership of a job.
It runs inside the same session whose continuation is in question and cannot
recover a process that is no longer executing.

Claude Code's documented Stop lifecycle also has bounded repeated blocking.
Native interactive agent teams and print-mode execution have different
capabilities. An implementation that assumes an infinite Stop-hook loop or that
it can attach a print-mode worker to an existing interactive team would build
on the wrong contract. See the official [Stop hook reference](https://code.claude.com/docs/en/hooks#stop-input)
and [agent teams documentation](https://code.claude.com/docs/en/agent-teams).

The design decision is therefore to keep action-specific protections and put
continuation, completion criteria and recovery into application code. Another
declaration parser would leave the central failure mode intact.

## What was built

A shared Rust controller executes an explicit finite plan. The plan contains a
workspace, task dependencies, acceptance commands, an attempt budget and a
model-attempt timeout. The controller journals the contract before executing it.

The normal path is:

```text
pending -> running -> verifying -> passed
                         |
                         +-> pending, while attempts remain
                         +-> needs_attention, when the budget is exhausted
```

An ordinary model `end_turn` advances execution to verification. It cannot mark
the task passed. The host runs the acceptance commands and records their results.
Failed acceptance leads to another attempt with that evidence. Dependencies
gate task selection, while unrelated ready work can proceed after a failure.
Earlier tasks are checked again against the final workspace before completion.

A synced append-only journal and an OS writer lock preserve execution ownership
and committed state. Reopening after an interrupted attempt records that it
needs inspection. It does not blindly repeat an action whose effects are unknown.
Pause and cancellation are explicit persisted states, never completion signals.

Two adapters use the same controller:

- RichOS desktop: a Work plan panel loads a prepared JSON plan, shows its scope
  and controls execution through the existing scoped Spine and cancellation path.
- Terminal: `richos-run` uses the existing native model adapter in any explicitly
  selected workspace. Its status distinguishes completed from unfinished work.

The implementation contains no repository-specific backlog discovery. Adding a
provider or host should preserve the controller's state machine rather than
reimplementing its decisions in prompts. Usage and plan format are documented
in [MANAGED-RUNS.md](MANAGED-RUNS.md).

## How the implementation was checked

The investigation began with the requested transcript interval and the installed
guard implementation, then checked the relevant provider lifecycle documentation.
The fix was developed in an isolated Git worktree. It does not modify the active
team session, the installed guards or the other agent's guard patch.

The controller regression suite has 16 tests. It covers early model termination,
acceptance failures, bounded retries, dependencies, final-workspace regression,
provider failure, timeout, pause, cancellation, journal locking and restart
recovery. Integration coverage includes the actual Spine path and real verifier
processes. A CLI test launches a real child process speaking a controlled native
protocol: its first turn ends without the artifact, its second creates it and
only the successful artifact check permits completion.

Four mutation checks deliberately remove acceptance gating, attempt bounds,
interruption reconciliation and writer locking in disposable copies. All four
were caught by their designated regression tests. Compilation failure does not
count as detection.

The desktop backend compiles. The nine focused UI tests cover preparation before
execution, pause, cancellation, visible errors and stale event rejection. The
broader core suite passed. The broader UI run exposed appearance, affordance
inventory and documentation issues, which were corrected and checked separately.
This is controlled integration evidence, not a live production model-team trial.

Useful review commands, from the repository root:

```sh
cargo test --manifest-path app/Cargo.toml -p richos-core
cargo check --manifest-path app/src-tauri/Cargo.toml
python3 app/scripts/test-managed-run-mutations.py
node app/ui/tests/runs.js
node app/ui/tests/appearance.js
node app/ui/tests/affordances.js
node app/ui/tests/docs-claims.js
```

The browser tests require the Playwright setup described in
[ui/tests/README.md](ui/tests/README.md).

## Review map

| Area | Files | Main question |
| --- | --- | --- |
| Contract and scheduler | `crates/richos-core/src/run.rs` | Can any path claim completion without the required checks? |
| Execution and verification | `crates/richos-core/src/run_host.rs` | Are timeouts, cancellation and verifier results handled honestly? |
| RichOS execution scope | `crates/richos-core/src/run_spine.rs`, `crates/richos-core/src/spine.rs` | Does every managed attempt retain the correct workspace and binding? |
| Desktop lifecycle | `src-tauri/src/managed_runs.rs`, `src-tauri/src/main.rs` | Can pause, restart or competing commands duplicate execution? |
| Terminal adapter | `crates/richos-core/src/bin/richos-run.rs` | Do exit codes and recovery expose unfinished work accurately? |
| Operator controls | `ui/runs.js`, `ui/main.js` | Can the user see scope, evidence and the true run state? |
| Regression evidence | `crates/richos-core/tests/run_tests.rs`, `ui/tests/runs.js`, `scripts/test-managed-run-mutations.py` | Do tests fail when the promised properties are removed? |

Paths in this table are relative to `app/`.

## Limits and migration work still required

- This version runs managed tasks serially. A durable parallel worker pool is
  not implemented. It does not take ownership of an existing interactive team.
- Scope must be supplied as a prepared plan. Automatic natural-language planning
  and migration of scattered Markdown backlogs are not implemented.
- The host must stay running. There is no installed background service or
  machine-start recovery daemon. Restart recovers state and exposes uncertainty;
  continuation after an interrupted attempt requires inspection.
- Acceptance commands are trusted code and are only as meaningful as their
  assertions. Workers with the same OS permissions can alter verifier files.
  This is not a security boundary or proof of subjective product quality.
- Verifier timeouts kill the direct child. Verifiers must clean up their own
  subprocesses. Exactly-once external side effects are not guaranteed.
- A retry budget or genuine failure can still stop progress. The difference is
  that the run remains visibly unfinished with evidence, rather than treating a
  conversational ending as success.

For rollout, choose a small real RichOS task with independently meaningful checks,
run it through this controller and review its journal and deliverable. Exercise
pause and process interruption before expanding scope. Then add planning and
parallel scheduling against the same state contract where needed. Existing
action-specific guards should be retired individually only when their protection
has an identified replacement.
