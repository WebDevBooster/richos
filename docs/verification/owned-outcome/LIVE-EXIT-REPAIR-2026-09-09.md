# Repair of the first installed Claude Code exit failure

Scope: repair the owned-outcome installation that interfered with ordinary
Claude Code exit. No new skills, agent responsibilities or business work were
added. Unrelated improvements remain in POST-R7-TODO.md.

## What failed

The installed inspector received accumulated execution records inside its first
prompt. In the reported session the inspection input was about 2.4 MB and the
provider rejected requests above its million-token context limit. A failed
inspection was then converted into the same continuation instruction used for
proven unfinished work. This sent the leader into more diagnosis and repeated
verification instead of allowing normal exit. Three failures also armed the
existing one-hour backoff.

The accompanying skills warning was false. Inspectors deliberately do not load
the chat skills. The common startup reader nevertheless reported their absence
as rejection and claimed a skills preflight had succeeded. No Claude version
regression was established. The correction scopes that check to leases that
actually request chat skills; it does not add skills to inspectors.

The installer also embedded the stable checkout and adopter workspace paths in
tracked settings, then rewrote the file as one line. Preserving permissions did
not make those machine-specific settings portable.

## Changes

Large audit input now travels through a private content-addressed snapshot with
an exact SHA-256 check. The provider receives a bounded index instead of the
execution history pasted into the prompt. Full conversation, provenance,
permissions and background-task context remain in ordered source pages. Full
execution observations remain available separately for targeted inspection.
Nothing in the retained ownership state is truncated to make a prompt fit.

The inspector must successfully read every source/context page before a verdict
is accepted. The host checks the Read receipts against expected page content;
claims of reading, failed calls, partial reads and different content do not count.
Pages use short lines to avoid native Read line truncation and fit beneath the
machinery receipt limit. The snapshot directory alone is added to the inspector's
read scope. Worker permissions remain unchanged. Source files are published
atomically so an interrupted write cannot leave a partially published page.

Inspection infrastructure failure is not evidence of unfinished business work.
It leaves the assignment explicitly unverified and allows normal native exit,
with a diagnostic rather than a blocking continuation. Unchanged failed input
is not repeatedly submitted. Changed evidence or an updated runtime permits a
new inspection without inheriting an obsolete error backoff. An actual valid
incomplete verdict still invokes continuation for authorized unfinished work.

Installed hook commands now resolve the engine through the user-local
`richos-engine` pointer and resolve the workspace at runtime. Machine-specific
runner configuration stays in ignored local storage. Reinstallation migrates
the existing commands and restores readable JSON while preserving permissions,
team settings and unrelated hooks. The portable hook additions remain a real
tracked adoption change in femcboost; they are not silently hidden from Git.

## Validation and limits

The native adapter suite passes 139 tests, including actual hook CLI checks:
context errors, timeout diagnostics and unreadable evidence all exit zero with
non-blocking JSON diagnostics and empty stderr. An unchanged retry is silent and
makes no inspector call. Replacing the runner triggers a fresh inspection; a
valid incomplete verdict still exits two for normal continuation. Installer
checks pass 5 tests and dispatch checks pass 33 tests. Rust core validation passed
595 tests with one ignored test, followed by 5 passing targeted review-control
tests after the final unavailable-verdict and escalation-budget changes.

The reported 2.4 MB session state was replayed read-only. After evidence-directory
access was corrected, the oversized-prompt error was gone, but inspection hit its
240-second limit while reviewing the old work. That session's completion remains
unverified. This repair treats that timeout as a non-blocking inspection failure;
it does not claim the session's business outcomes passed review.

A separate real-provider fixture with 2,400,650 bytes of retained audit data
completed in 65.8 seconds, exit zero with empty stderr. It verified the exact
proof file and all required source/context pages, with no skills warning. Its
transport envelope was 190 bytes. This was an isolated fixture, not a completion
claim for the production conversation. Its tested runner SHA-256 is
`8c189e0319793db6aff2a3859cd2e08da6cd1644824fc098d06cd60684858d61`.

## Installed correction

Runtime commit `9e3d2edb` was fast-forwarded from the separate repair worktree to
stable main. A stable-checkout build was installed outside Cargo and worktrees.
Its SHA-256 is
`2cf658aef485d2800aece84759d04acc9845d3e24fe61c7d84ff8c8a6dd86cfe`.
This build uses the same Rust sources as the isolated provider trial above;
its build location and binary identity differ and are recorded separately.

The stable engine installer refreshed all required sidecars. All three adopters
(richos, richos-hq and femcboost) were migrated and verified: ten owned hooks per
workspace, zero `/Users/` strings in settings, readable JSON and all pre-existing
permissions, non-hook settings and unrelated hooks preserved. Dispatch integrity
passes with the actual adopter cwd and project environment. The first cross-root
probe omitted that environment and correctly failed; its result is retained.

The installed Python hook passed the actual CLI exit-contract regression. The
stable Rust binary also passed five scripted-transport inference lease checks.
No additional paid replay of the unchanged stable-build sources was claimed.

An old audit process (PID 54089) was still waiting in the pre-fix hour-long
backoff. Its exact command and parent were verified and it had no children.
It was terminated so it could not emit an obsolete wake. The native Claude
parent (PID 20597) was not signalled and remained running. Production ownership
records were not erased or marked complete.

The initial actual-session replay exposed an unreadable evidence directory.
The required-source check rejected that verdict. The inspector now receives
access to its exact evidence directory, with read-only tools retained. That
failed replay is preserved with the corrected replay, rather than reported as
successful inspection.

These changes bound the initial inspection prompt. They do not claim unlimited
model context: exceptionally large source conversations can still exceed a
lease's total context while being read. Such an inspection failure must permit
exit with an unverified outcome, not drive a continuation loop or silently
certify completion. General multi-lease inspection is outside this repair.

Private replay input and logs are retained at
`/Users/alex/.codex/artifacts/richos-live-repair-20260909`.
The replay reads a frozen copy of the reported session state and does not mutate
its production ownership state or execute business work.
