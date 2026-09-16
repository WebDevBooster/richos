# Repository audit, third pass, 2026-09-16

Audited revision: `854fa1e3`.

Four newly identified issues remain: two data-loss defects, one capture-storage
boundary bypass and one missed recording anomaly. All four were reproduced
against the current implementation using disposable fixtures. No production
code was changed.

These are **pre-existing defects**, not demonstrated regressions from the recent
refactors. The capture handler, watcher, ledger and steering files are byte-identical
to their pre-relocation versions at `3bed39a1`. The relevant workspace landing
and deletion functions are also identical at the Python AST level. The two earlier
audits and their fixes were reviewed to avoid reporting already resolved findings.

## 1. P1: Landing can delete work written during process shutdown

Source: [workspaces.py](../../richos/engine/mega-lander/workspaces.py),
lines 3082-3084, 3121-3128 and 3169-3194.

`land()` checks for uncommitted files and proves branch ancestry while workspace
processes are still running. It then records the work as landed. Only afterward
does `_delete_chain()` stop those processes, followed by forced worktree removal.
There is no second cleanliness or ancestry check after shutdown. A process that
flushes a result during its SIGTERM handler can therefore create uncommitted work
after the only check and have it deleted immediately.

**Executed reproduction:** Use the repository's isolated workspace test fixture
to register and finish an agent with clean, fully merged worktrees. Start a real
Python process in its cross-repo worktree. The process waits for SIGTERM, writes
`shutdown-result.txt`, reports `FLUSHED` and exits successfully. Call the real
`land()` without mocking its cleanup or Git operations.

```text
uncommitted before land: [[], []]
child output: FLUSHED
child exit: 0
land result: {"landed": true}
worktree exists: false
result in main checkout: false
```

The newly written file is lost. This also affects automatic landing, which uses
the same function. The proof concerns a shutdown write, so it does not depend on
winning a narrow timing race.

**Fix:** Stop and join workspace writers before the final cleanliness and ancestry
checks. Record the landed disposition only after those checks pass. Apply the
same protection to deletion retries so a previous eligibility check cannot
authorize deleting later work. Keep explicit discard semantics separate.

## 2. P1: Recovery from an incomplete log line loses the next accepted input

Sources: [ledger.rs](../../richos/app/crates/richos-core/src/ledger.rs),
lines 670-692 and 1301-1309;
[steering.rs](../../richos/app/crates/richos-core/src/steering.rs), lines 490-499.

Both logs can reopen a file whose final JSON record is incomplete. Replay reports
the damaged record and continues. Neither writer establishes a newline boundary
before its next append, so the next valid record is attached directly to the
damaged bytes. The append returns success, syncs the bytes and updates the in-memory
view. On the following restart, the combined line is rejected and the new input
disappears along with the old damaged record.

**Executed reproduction:** A separate Rust program imports the actual core crate.
It creates a valid thread, appends a synthetic incomplete record without a newline,
reopens the ledger and calls `record_prompt_received()`. It then closes and reopens
the ledger again. A second case uses the public `TurnControl::steer()` API.

```text
original_survived_tail_damage=true
record_prompt_received_returned_ok=true
new_prompt_visible_in_process=true
new_prompt_survives_restart=false
steer_returned_ok=true
pending_steering_before_restart=1
pending_steering_after_restart=0
```

These are the APIs that promise persistence before delivery, including fsync.
The existing torn-intake test verifies the first replay but never appends another
message and reopens a second time, so it misses this failure.

**Fix:** Preserve damaged bytes while durably separating an unterminated tail from
new records before accepting another write. Audit the other append-only stores
for the same pattern. Add recovery tests that append and restart after detecting
a torn tail, rather than stopping at the first successful replay.

## 3. P1: The native capture host can still write recordings into the product tree

Source: [host-handlers.js](../../richos/tools/richos-service/lib/host-handlers.js),
lines 31-32 and 63-82.

The native host validates the drop-zone root at startup, but `SessionSink` joins
the message's session ID onto it without checking the resulting destination.
`session-start` then creates or follows that directory and writes `session.json`;
`audio-chunk` appends recording bytes there. A `../` session ID can escape the zone.
A normal single-component ID can also follow an existing child symlink into the
product checkout. The pipeline boundary fixed in the preceding audit runs after
capture and cannot prevent these earlier writes.

**Executed reproduction:** Copy the real host and service modules into a disposable
grouped product tree, configure an external recording zone and send real
length-prefixed native-messaging frames. Both a traversal ID and a child symlink
produce successful `started` and `chunk-ack` responses and create synthetic audio
plus session metadata under the fixture's product `docs/` directory. A normal
external session works as expected. As a control, the same product destination
configured directly as the zone is refused by the host's privacy check.

This demonstrates a local write-boundary bypass. No real audio, credentials,
remote browser exploit or disclosure was used or demonstrated.

**Fix:** Validate session IDs as single path components and enforce physical
containment at the capture writer. Check actual output destinations before
opening them, including symlinked child directories and files. Constrain the
audio extension field too, since it participates in the output filename.

## 4. P2: Reconciliation reports abandoned open recordings as healthy

Source: [watcher.js](../../richos/tools/richos-service/lib/watcher.js), lines 92-97.

`scanZone()` unconditionally skips every record with `status: "open"`, even though
the shared reconciliation function has already identified it as an anomaly. It
does not check the age or heartbeat before skipping. The in-memory host watchdog
cannot recover sessions from a previous host process, and abrupt process or machine
termination need not run the EOF finalizer. Such sessions remain skipped forever.

**Executed reproduction:** Put a synthetic open session with audio and an ancient
start time and heartbeat in an external zone. Run the actual CLI's `reconcile`
command against that zone.

```text
exit: 0
ok/skipped: 1
no anomalies
```

The recording has no transcript and no live owner, but the recovery check gives
a clean result. This is independent of the host path issue above.

**Fix:** Distinguish actively owned sessions from abandoned ones using durable
ownership and heartbeat evidence. Surface stale open sessions in report-only
reconciliation and the watcher's recovery path without transcribing an active call.

## Verification and evidence

New reproductions:

- [reproduce.py](repo-audit-third-pass-2026-09-16/reproduce.py): real native-messaging
  host, reconcile CLI, workspace lifecycle and a Rust consumer of the real core.
- [ledger_probe.rs](repo-audit-third-pass-2026-09-16/ledger_probe.rs): log-recovery probe.
- [results.json](repo-audit-third-pass-2026-09-16/results.json): captured reproduction results.
- [ledger-probe.log](repo-audit-third-pass-2026-09-16/ledger-probe.log): Rust results and diagnostics.

Run from any directory with Python 3, Node, Git and Rust available on macOS:

```sh
python3 /path/to/repo/docs/verification/repo-audit-third-pass-2026-09-16/reproduce.py
```

Rust dependencies must be cached because the probe builds offline. All test
writes and process termination happen in disposable fixtures. The default
results directory is temporary. Optional arguments select the repository root
and results directory.

Existing tests rerun at the audited revision:

| Area | Result |
| --- | --- |
| Rust core, integration and documentation tests | 991 passed, four ignored |
| Service | 335 passed |
| Workspace source | 73 passed |
| PreToolUse dispatcher | 36 passed |
| Mega Lander workspace specification | 68 passed |
| Mega Lander relocation | Six passed |
| Root resolution | 30 passed |
| Engine asset packaging | 18 passed |

Engine behavioral suites used `RICHOS_MUTATION_INNER=1`; this is not a new mutation
campaign. All listed test commands completed with exit 0. Full logs remain under
`/tmp/richos-third-audit-20260916`. The initial Cargo command could not resolve Cargo
from PATH; the completed run explicitly added the installed Rust toolchain.

The source review also covered relocation diffs, dispatcher aggregation, hook
dependency discovery, release packaging, update staging and Workspace ingest.
That review does not establish exhaustive coverage of those systems. This pass
did not repeat the 141-unit engine campaign, browser UI suites, voice tests or
native platform builds. It did not use live accounts, record audio or publish
anything. The previously documented Windows recording-location issue remains
outside these four new findings. The intentional CI pause was left unchanged.
