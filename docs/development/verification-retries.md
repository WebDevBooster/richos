# Verification: unresolved failures first, preserve valid results

This procedure is mandatory for implementation agents, reviewers and
orchestrators. Its purpose is to obtain the required evidence without repeatedly
spending the user's time on unchanged passing work. It supplements the existing
proof selector, runner, resource controls and receipt verifier.

## 1. Before launching any verification

Inspect the existing run directory, progress, summary, logs and receipts. Record:

- The exact selected plan and why each relevant suite was selected.
- The tested commit, tracked diff and untracked-source fingerprint.
- Passed, failed, timed-out, refused, cancelled and unrun units separately.
- The relevant toolchain, dependencies, fixtures, platform and execution settings.
- Which results remain applicable and the exact unresolved evidence gap.

Start from the smallest unresolved unit. A new agent, context compaction,
handoff, user status question or interrupted parent process does not by itself
invalidate completed passing work. Do not start a fresh full run just because
you have lost track of the old one; recover its evidence first.

Keep the existing optimized defaults. Inspect inherited environment variables as
well as command-line flags. In particular, do not silently set
`RICHOS_MUTANT_JOBS` or `--engine-shards`. A CPU-admission refusal is not evidence
that the test code failed or that the machine is inherently slow. Inspect the
recorded admission reason, CPU samples, worker leases and owned processes before
choosing a remedy. Preserve CPU limits, shared worker budgets and build locks.

## 2. Before any retry

Run failed, timed-out, refused or previously unrun units before repeating
unchanged passing units. Inspect the failing unit's own log, including nested
suite output; a wrapper's failure label is not a diagnosis.

Classify the failure accurately:

| Outcome | Next action |
| --- | --- |
| Assertion failure | Diagnose the assertion, fix the cause and rerun its owning unit first. |
| Deadline reached | Inspect actual progress and concurrency overrides; retry the unit alone with normal parallelism before widening scope. |
| Admission refused | Resolve or wait for the recorded resource condition; retry the refused unit first. |
| Interrupted run | Preserve finished receipts and identify exactly what never reached a verdict. |
| No screen or missing device | State the missing coverage. Do not turn a successful wrapper exit into a test pass. |

Do not make several speculative execution changes between attempts. A necessary
non-default setting needs a recorded observation, the setting before and after,
the expected effect and the result of a bounded experiment on the affected unit.
Timeouts must remain finite. Do not remove resource guards or reduce assertions
to obtain green output. Longer admission waits and unit deadlines are different
controls and must not be confused.

Before a broad rerun, write a short decision record containing all of:

1. The unresolved unit and the result of its isolated retry.
2. The source, dependency, fixture, toolchain or relevant environment change that
   invalidates earlier results, or the specific gate requiring a fresh run.
3. Why applicable receipts cannot cover the required plan.
4. The exact command, inherited overrides and measured runtime basis.

This is the agent's decision record, not a new user-approval step. Do not make
the user manage test ordering, diagnose the runner or approve routine checks.

If the record has no concrete invalidation or fresh-run requirement, do not
restart the broad selection. User impatience is not a reason to skip proof;
it is also not a reason to discard valid proof and start again.

Do not leave a known failing prerequisite at the end of a long queue. If a run
must be stopped or reordered, use its recorded process ownership and cleanup
mechanism. Preserve evidence first. Do not select processes to kill by name or
path, touch another task's processes or call cancellation a pause.

## 3. Before accepting reused results

Reuse is evidence validation, not optimistic caching. Check source identity and
the relevant inputs and execution conditions. A matching commit alone does not
prove a dirty checkout, changed dependency, toolchain or external fixture was
unchanged. If identity cannot be established, rerun the affected units.

The engine already supplies `scripts/lib/ci-receipts.py verify`. For an unchanged
tested commit, keep one actual passing receipt per planned unit, replacing only
the unresolved unit with its successful retry. Retain the superseded failure and
record the provenance of every selected receipt. Never manufacture a verdict,
edit its SHA or overwrite the failed run's summary.

Verify the selected receipt set against the original plan. The existing verifier
rejects missing, duplicate, unplanned, non-green and mixed-commit receipts. Also
check the source fingerprint and relevant environment independently; the receipt
verifier is not a general environment-equivalence checker. For non-engine checks,
preserve their full-run summary and logs and verify their actual scope and status.
Do not invent a general proof-run resume/cache feature that does not exist.

If a required gate explicitly demands a fresh single invocation, preserve that
requirement and run it after resolving the blocker. A request for full coverage
alone does not require discarding applicable passing evidence. If only a
reconciled result exists, say that plainly; never claim the original command
exited 0 when it did not.

## Communication and completion

Separate implementation completion from verification completion. State the actual
unresolved blocker and why the next command is needed. Base estimates on observed
durations and disclose uncertainty. Do not blame hardware without measurements
or hide execution overrides behind a generic statement that tests are slow.

When a unit exceeds its measured duration or stops showing progress, inspect its
own log and execution settings before simply raising a timeout. Repetitive
progress counts do not replace diagnosis.

Stop running tests once the required evidence is complete. Do not broaden or
repeat testing without a new change, failure or unresolved coverage concern.
For documentation-only follow-ups, check the changed instructions, links and
formatting, plus a directly affected rendering/provisioning check if necessary.
Do not replay an unrelated application or mutation suite.

The final report must identify the tested code, plan, reused evidence, retry
results, skipped coverage and the distinction between a single clean run and
reconciled verification. Preserve useful evidence before deleting owned scratch.

## Enforcement boundary

These are mandatory agent instructions. The existing coverage verifier and
resource guards provide mechanical checks for their specific invariants. This
change does not add a universal command interceptor, a general result cache or
automatic failed-first scheduling. Do not claim that instructions alone make
recurrence technically impossible. A future mechanical change must preserve
source/input identity checks, truthful failures and required coverage.
