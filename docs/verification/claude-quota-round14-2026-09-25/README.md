# Desktop Claude Code quota: round 14

Implemented in the isolated `codex/claude-quota-settings` worktree. This updates
[the initial quota implementation](../claude-quota-2026-09-25/README.md). Source
changes are committed locally; no installed app or release was changed.

## Interface

The Technical view settings entry now includes a usage preview and an observed
paused-agent count. The sheet uses a prominent five-hour **used** figure, a gold
usage ruler, an elapsed-time tick and a labeled pause threshold. Weekly windows
are compact secondary rows. Provider model labels remain dynamic; fixtures use
Fable. Missing windows have no invented bars. Stale readings are labeled and
hatched, including after a known window expires.

The automatic-pause switch saves immediately. Threshold drafts have Save and Keep
actions, immediate validation, Enter to save and Escape to discard before closing.
The active threshold stays in force until a valid save succeeds. "Let them continue
now" disables automatic pausing. A failed refresh retains old figures and respects
the existing ten-minute retry backoff.

The five-hour rule remains: default 93% used; do not hold when reset is strictly
less than 20 minutes away. Exactly 20 minutes still holds. Refresh every five minutes
at every usage level. Known reset deadlines can bring a refresh forward. Ordinary conversation remains available.

## Observed pause state

A waiting hook owns an exclusive file lock until admission succeeds or the wait
ends. The reader probes shared locks, so concurrent status reads do not masquerade
as active waits. Dead or stopped processes cannot leave a live paused-agent count.
Successful admission writes brief release evidence; stopping or killing a waiter
never claims resumption. Multiple waiting steps from one agent count once.

Names and tasks are enriched from the matching company, thread, session and agent
receipt. Raw agent IDs are the fallback when no matching name is recorded.
Assignments and new-agent dispatches are shown separately from existing agents.
The panel reads app-wide waits; conversation status is thread-scoped.

The conversation chip separates paused agents from the provider's active count.
The work-summary pane also marks those agents paused. Ordinary view says their
work is saved; Technical view additionally gives the quota reason and earliest
reset-exception time. A high usage reading without wait evidence says ready to
pause, not that agents are already paused.

Shutdown now includes pre-lease work and final receipt writes in its existing
bounded drain. Testing exposed a race where a paused runner could write after the
shutdown sweep. The drain remains bounded at two seconds.

## Verification

- Full core library suite: **781 passed, one existing ignored test**.
- Includes actual child-process termination, deduplication, scoped name lookup,
  pause/resume boundaries, stop and unknown-reading behavior.
- Desktop `cargo check`: passed with existing warnings.
- WebKit quota suite: **13 checks passed**, including both themes, state variants,
  threshold keyboard controls, thread-scoped conversation status and release.
- Settings fit, Escape, worker presentation and background-work suites passed.
- Readable text meets 4.5:1 contrast, or 3:1 for large text. Gold, ink markers and
  control borders meet 3:1 against the panel. Type follows round 14's 16px floor,
  with the declared 11px eyebrow and 14px weekly axis annotations.
- Layout verified at 1024×700 with reachable scrolling controls. Both themes fit
  at 1440×900 without panel scrolling, including three observed agents.
- Screenshots were visually inspected. They use fixture values and names in the
  implemented renderer, not live account usage or a recreated mockup.

Commands, with Cargo caches on the external SSD:

```sh
cargo test -p richos-core --lib --quiet
# richos/app/src-tauri
cargo check --quiet
# richos/app/ui/tests
node quota.js
node settings-fit.js
node escape.js
node workers.js
node background-work.js
```

Live quota reading and retained-hook subprocess smoke verification from the
initial implementation remain documented in its report. This revision adds real
process-lock observation and renderer verification, not a five-hour live run.

## Screenshots

- [Dark, holding three agents](holding-dark.png)
- [Light, holding three agents](holding-light.png)
- [Dark, minimum desktop window](minimum-dark.png)
- [Light, minimum desktop window](minimum-light.png)

The follow-up desktop change fixes polling at five minutes throughout the usage
range and requests a check immediately at app startup and each new foreground or
background Claude session, including replacement leases. The monitor runs even
when automatic pausing is off. A session-start signal wakes the shared reader
without blocking session launch or Stop controls on provider I/O. Concurrent starts
share an in-flight or just-completed reading through the existing five-second
cooldown. Failure backoff still applies. Sign-in completion and setup changes also
wake the reader after clearing the old account or binary's cache.

The engine quota watcher and private HQ rulings page were not changed.

Follow-up verification: 19 targeted quota Rust tests, 13 WebKit quota checks and
the desktop Cargo build check passed.

## Merge proof registration

Rebased `codex/claude-quota-settings` onto `origin/main` at `eca57bc1` without
conflicts. The designer's round-14 implementation remains in the branch.

- `proof-for.ui-inputs` now declares the quota UI suite and its shell, quota,
  settings and mock inputs.
- The probe's existing Unix tests use separate `cfg(test)` and `cfg(unix)`
  attributes so the selector discovers them while preserving their platform gate.
- `scripts/claude-quota.test.sh` claims the smoke example it actually runs. Its
  five checks cover argument refusal, control-only reads and scratch cleanup,
  provider EOF, retained callback handoff and revoked-work refusal. No account
  credentials or model turns are needed. No exclusions were added.
- Rebase verification: 16 quota module tests, five example subprocess checks,
  nine declaration-contract tests and the 13 quota UI checks pass. ShellCheck
  also passes for the new suite.

The requested command is `bash richos/app/scripts/proof-for.sh origin/main..HEAD`.
It exits **0**, including the quota UI suite, probe unit target and example suite.
This proves the coverage mapping reconciles; the selector prints commands and
does not execute every selected suite. The checks actually executed are listed
above. The engine watcher and HQ rulings page were not edited.
