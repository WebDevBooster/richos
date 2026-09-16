# Repository audit after the refactors, 2026-09-16

**Follow-up:** The six findings are fixed. See the [fix and recheck report](repo-audit-post-refactors-fixes-2026-09-16.md). The findings and results below describe the original audited revision.

Audited revision: `e9831589`.

Six actionable issues were reproduced. Two are remaining storage-boundary gaps;
four affect persistence, source identity or guard health reporting. No product
implementation was changed.

These are pre-existing defects, not demonstrated regressions from the directory
refactors. The Workspace and service ledger modules involved are byte-identical
to their versions at `3bed39a1`, before product relocation. The pipeline's later
directory check did not change its file writers. The stated-action wrapper's
changes since that revision only relocate the analyzer and self-test paths.
[Source identities](repo-audit-post-refactors-2026-09-16/source-identities.json)
retain the comparisons for the unchanged modules.

## 1. P1: Pipeline file writes still escape the checked session directory

Source: [pipeline.js:87](../../richos/tools/richos-service/lib/pipeline.js#L87),
with the directory-only check at line 100 and further output writes at lines
826 and 833-834.

`runPipeline()` validates the physical session directory, then writes fixed
filenames with ordinary `writeFileSync`. An existing `session.json` symlink or
hard link can target a file in the product checkout even when the session
directory is safely outside it. The capture writer now rejects these links;
the pipeline does not use that writer.

**Reproduction:** In a disposable product copy, create an external session whose
`session.json` links to a synthetic record in the product's `docs/` directory.
Run the actual pipeline with a no-audio record. Its anomaly path returns normally
and overwrites the linked product file. Directly selecting that product directory
is refused by the privacy validator, confirming the bypass is at the file level.
No speech tools or real recording are required for this reproduction.

**Impact:** The pipeline can modify product files through accepted external
storage. The same unchecked write pattern exists for transcript and verification
outputs. The executed proof concerns metadata, not a demonstrated transcript leak
or remote exploit.

**Fix:** Enforce physical containment and regular-file identity at every pipeline
output, including files written by normalization and transcription tools. Reuse
the capture writer's link checks where applicable. Test linked leaf files as well
as linked session directories, with an unchanged external-directory control.

## 2. P1: Workspace evidence follows linked children into the product checkout

Source: [evidence.js:68](../../richos/tools/richos-service/lib/workspace/evidence.js#L68),
especially directory creation and writes at lines 72-78.

The Workspace writer appends vendor, source, item and revision components to a
validated root, then creates directories and writes through any existing links.
It never validates the resulting physical destination. Validating the root in
configuration cannot protect against links below that root.

**Reproduction:** Create an accepted external Workspace zone with its `google`
child symlinked to the disposable product's `docs/` directory. Normalize a
synthetic Calendar event with the real adapter and call `writeEvidence()`.
The resulting `item.json`, `content.txt` and `governance.json` are physically
inside the product. The probe reads back the synthetic private body there.

**Impact:** Workspace evidence can enter the public product tree despite the
existing storage invariant. This finding is in the Workspace library API; the
audit did not establish a live account ingest or external disclosure.

**Fix:** Validate every derived evidence directory and output file against both
the configured zone and the product boundary. Refuse symlink and hard-link
outputs before writing. Add child-directory and leaf-file regression cases to
the complete ingest path.

## 3. P2: The two JavaScript ingest ledgers still lose the next row after a torn tail

Sources: [ledger.js:39](../../richos/tools/richos-service/lib/ledger.js#L39) and
[workspace/ledger.js:42](../../richos/tools/richos-service/lib/workspace/ledger.js#L42).

Both readers tolerate malformed JSONL records, but both appenders concatenate
the next JSON object directly onto an unterminated tail. The recent Rust log
recovery fixes did not cover these JavaScript stores.

**Reproduction:** Write `{"torn":` without a newline, then append a valid row
through each public ledger API. Both return `appended: true`. Both immediately
report the accepted row absent through `alreadyLedgered()` or `alreadyIngested()`.
The resulting physical line is malformed JSON containing both records.

**Impact:** A completed transcription can have no readable ingest receipt.
Workspace deduplication can re-ingest a version that was already accepted.
This probe demonstrates loss of the receipt, not deletion of the recording or
evidence body.

**Fix:** Establish a durable record boundary before appending after a damaged
tail. Preserve damaged bytes for diagnosis. Test append and reopen after a torn
tail in both stores, including a later undamaged record.

## 4. P2: Different evidence revisions collide and overwrite historical evidence

Source: [evidence.js:31](../../richos/tools/richos-service/lib/workspace/evidence.js#L31)
and its unconditional writes at lines 76-78.

`revToken()` removes punctuation and truncates the remaining etag to 24
characters. Distinct opaque revision identifiers can therefore resolve to the
same directory. The ingest ledger retains the original etags and considers
them different versions, but the evidence writer overwrites the earlier files.
It even returns `written: false` after changing their contents.

**Reproduction:** Normalize the same synthetic event with etags `"abc-def"`
and `"abcdef"` and different bodies. Both resolve to `rev-abcdef`. After the
second write, reading the first revision's path returns the replacement body.
This is a collision of values accepted by the adapter and evidence contract;
the audit did not measure its frequency in live Google responses.

**Impact:** Historical citations can silently change meaning, defeating the
writer's immutable-version contract. Distinct source IDs also pass through a
lossy filename sanitizer and should be included in the correction.

**Fix:** Derive storage keys from a collision-resistant digest or reversible
encoding of the full source identity and full etag. Refuse conflicting contents
at an existing revision path instead of overwriting. Test punctuation collisions,
long shared prefixes and repeat writes of the same version.

## 5. P2: Calendar sync state is shared across different calendars

Source: [core.js:59](../../richos/tools/richos-service/lib/workspace/core.js#L59),
[sync-state.js:17](../../richos/tools/richos-service/lib/workspace/sync-state.js#L17)
and [google-calendar.js:116](../../richos/tools/richos-service/lib/workspace/adapters/google-calendar.js#L116).

The adapter supports `calendarId`, but the core keys its cursor only by
`vendor:source`. Every Calendar adapter using one zone therefore reads and
replaces `google:calendar`, regardless of the calendar being polled. The item
identity also omits the calendar and account.

**Reproduction:** Run `ingestOnce()` for calendar `first`, returning
`first-token`, then run it for calendar `second` in the same zone. A mock HTTP
client records the actual URL built by the real adapter: the request to
`/calendars/second/events` contains `syncToken=first-token`. No live API call was
made, so this report does not claim a particular Google error response.

**Impact:** Switching calendars or polling multiple calendars reuses another
resource's cursor. Matching event IDs can also collide in deduplication and
evidence storage. These are library-level findings; no live multi-calendar
installation was exercised.

**Fix:** Give each source instance a stable identity incorporating account and
calendar. Use it consistently for cursors, item IDs and evidence paths. Migrate
the old cursor explicitly and test two adapters sharing one zone.

## 6. P2: A crashed stated-action analyzer is reported as recovered

Source: [guard-stated-actions.sh:278](../../richos/engine/scripts/hooks/guard-stated-actions.sh#L278),
especially the unconditional normal notice at lines 293-295.

The wrapper records the analyzer's exit status but only distinguishes status 2
at its final return. A runtime exception with status 1 still calls
`stop_notice_normal()`. On an initially healthy session this is silent. After
an abnormal state it emits a false `RUNNING AGAIN` notice.

**Reproduction:** In the relocation suite's disposable engine, run one Stop call
with `CHECK_STATED_ACTIONS=0`. Re-enable the check and submit an otherwise valid
JSON payload with numeric `last_assistant_message`. The real analyzer raises
`AttributeError` at `message.strip()`. The wrapper exits 0 and emits
`STATED-ACTIONS GATE ... RUNNING AGAIN`. A subsequent correctly typed control
input succeeds. Neither the wrapper nor analyzer was modified for this probe.

The malformed field is a fault-injection input, not evidence that the current
host normally sends numbers. It demonstrates incorrect reporting for any
unexpected analyzer exit, including an interpreter or import failure.

**Fix:** Preserve the intended fail-open behavior while reporting an abnormal
notice for analyzer exits other than 0 or 2. Emit recovery only after a successful
evaluation. Test healthy, failed and recovered transitions independently of the
blocking policy.

## Evidence and verification

[reproduce.py](repo-audit-post-refactors-2026-09-16/reproduce.py) runs the probes
using disposable product and engine copies. Its sibling
[service-probes.mjs](repo-audit-post-refactors-2026-09-16/service-probes.mjs)
imports the copied production modules. Run from any directory:

```sh
python3 /path/to/repo/docs/verification/repo-audit-post-refactors-2026-09-16/reproduce.py
```

[results.json](repo-audit-post-refactors-2026-09-16/results.json) retains the
observed outputs. [checks.json](repo-audit-post-refactors-2026-09-16/checks.json)
records completed checks and any retry separately.

| Check | Completed result |
| --- | --- |
| Rust core | 994 passed, 4 ignored |
| Tauri shell | 98 passed on retry after dependency-cache cleanup |
| User updater | 37 unit tests and 1 integration test passed |
| Rust voice | Full retry: 225 passed, 4 ignored; original run failed the live timing test |
| macOS companion | 41 passed |
| Service and Workspace | 345 and 73 passed |
| Extension | 66 passed |
| ASS Kicker relocation | 7 passed |
| Brief provenance, scope and stated actions | 47, 53 and 45 passed |
| Stated-action mutations | 31 of 31 detected, intact control passed |
| Mega Lander workspaces | 76 passed |
| PreToolUse dispatcher | 36 passed |
| Engine asset packaging | 18 passed |
| UI documentation contracts | 6 passed |

`RICHOS_MUTATION_INNER=1` ran the listed behavioral suites without their embedded
mutation campaigns. Only the stated-action mutation campaign was run separately.

The review covered relocation diffs and callers, workspace cleanup, hook
dispatch and dependency discovery, application storage and provisioning,
capture and transcription, Workspace ingest and engine packaging. This is
targeted source review and testing, not exhaustive proof of the whole repository.
The complete engine mutation campaign, browser UI campaign, Windows build,
live account integrations and delivered-nightly acceptance were not run.
The intentional CI pause was not changed.

The original Tauri test invocation failed because cached dependency build output
referenced the pre-relocation checkout path. Cleaning only the Tauri and updater
plugin dependency caches allowed the retry to pass. This was a local build-cache
problem, not a source finding.

The first voice suite run failed its existing live macOS synthesis performance
assertion: real-time factor `0.541`, required `< 0.5`. Its isolated rerun and subsequent complete voice suite rerun passed.
The original failed run remains a failure in the evidence; no threshold was
relaxed. Full test logs are under `/tmp/richos-audit-20260916-codex` on the audit host.
