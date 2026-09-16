# Third-pass audit fixes and final verification

All four findings in [the third audit](repo-audit-third-pass-2026-09-16.md)
were fixed, tested, merged individually into `main` and pushed to `origin/main`.
Rechecking found three follow-up problems, which were also corrected in separate
merges. A subsequent test-only correction repaired two stale container mutation
targets. Final product code revision: `a6f1c1c1d69da350b12b1d74a37423b93143529f`.
The test-harness correction is merged at `2262a180`.

## Changes

| Finding | Fix commit | Merge commit | Result |
| --- | --- | --- | --- |
| Landing deleted files written during shutdown | `3967b396` | `f81eb2b4` | Writers stop before cleanliness and ancestry checks; retries recheck eligibility and preserve newly written work |
| An incomplete log line swallowed the next accepted input | `6671a16c` | `c6b3ae42` | Ledger, steering, staging, correction and journal writers separate damaged tails before appending; accepted records survive another restart |
| Native capture could write outside its recording zone | `7851e13f` | `e3e358db` | Every capture write validates components and physical containment, rejects linked destinations and checks the opened file before truncating it |
| Reconciliation ignored abandoned open recordings | `87706a1c` | `1dd7257e` | Durable receipt-time heartbeats distinguish active sessions from stale ones; stale sessions produce an anomaly without being closed or transcribed automatically |
| Capture validation rejected legitimate encoded room names | `e841bd43` | `86cd7ff9` | Safe URL punctuation and encoded names remain valid within the path boundary |
| Damaged UTF-8 stopped three secondary log readers | `4e8dd0e5` | `ea3221c2` | Staging, journal and feedback parse individual byte-delimited records so one damaged record cannot hide subsequent valid records |
| The new retry guard stranded partially removed worktrees | `ebb901d4` | `a6f1c1c1` | When Git has already removed administrative metadata, cleanup verifies that remaining file contents and modes are preserved; changed or new files stay intact until saved |
| Container mutation targets referred to the old shutdown call | `0f3d25bd` | `2262a180` | Both controls disable the shared reaping operation; the complete container suite and its official receipt check pass |

The partial-removal correction also updates two mutation anchors to match the
new shutdown implementation. It does not remove the corresponding mutation
controls. The regression checks include preserving newly written files and then
successfully completing cleanup after those files have been saved.

The [final four-finding reproduction](repo-audit-third-pass-recheck-2026-09-16/reproductions.json)
ran against the final product revision with `--expect-fixed`. It confirms that
shutdown output remains in its worktree, accepted ledger and steering records
survive restart, both native-host escape attempts create no product files and
the abandoned recording returns reconcile exit status 2. Normal external capture
still succeeds. The five earlier audit probes were also rerun and retain their
expected fixed behavior. Original defective-behavior receipts remain unchanged.

## Completed verification

| Area | Result |
| --- | --- |
| Core and voice Rust workspace | 1,219 passed including documentation tests; eight ignored |
| Desktop Rust | 98 passed |
| Detached updater | 38 unique tests passed; the filtered child invocation is not counted twice |
| macOS capture companion | 41 passed with both a fresh build directory and the ordinary test command |
| Service and Workspace | 345 + 73 passed |
| Browser extension | 66 passed |
| Windows companion | Release build succeeded; all 26 portable core tests passed using .NET 8.0.424 |
| Packaging | All nine suites passed, 178 checks |
| Browser UI | All 31 suites passed, 554 checks and zero skips |
| Service model-integrity mutations | All 41 checks were observed failing under relevant mutations |
| Service pipeline fixtures | 29 checks passed; one optional personal-corpus check skipped |
| Native-host end-to-end fixtures | 10 checks passed, zero skips |
| Capture coordination and failover | 12 checks passed |
| Cross-surface pipeline | 26 checks passed; unavailable Windows capture surface skipped |
| Workspace lifecycle specification | All 76 tests and all 56 mutations passed |
| Fourteen-point lifecycle suite | All 14 checks, the cleanup self-check and all 85 mutations passed |
| Syntax at final product revision | All 380 Python files, 494 shell files and 193 JavaScript files passed |
| Engine checks outside suites | All six steps passed in an isolated clone of the final product revision |
| Full engine verification | All 141 units covered across 118 suites: 140 passed in the full campaign; the corrected container unit passed separately. Both official coverage checks passed |
| Publication completeness | Passed, including the new verification documents |

All 24 tracked screenshots regenerated by browser verification were restored
byte-for-byte. End-to-end audio tests used synthetic speech and fixture vocabulary.
The optional personal entity-memory check was unavailable and is not counted as
a pass. The eight ignored Rust tests remain unexecuted.

## Revisions, failed attempts and retries

The first application batch recorded launch revision `1dd7257e`. Follow-up merges
occurred while that batch was running, so those records are not presented as proof
of an immutable whole-repository run. The core/voice workspace, desktop and updater
were rerun at `ea3221c2`; the entire application subtree is identical at the final
product revision. Service tests were rerun at `a6f1c1c1`. UI, packaging scripts,
extension and companion sources are unchanged from the initial batch. Verified
[component tree identities](repo-audit-third-pass-recheck-2026-09-16/source-identities.json)
record these comparisons without rewriting historical receipts.

The initial Rust workspace run failed the voice synthesis timing check under
concurrent engine load: real-time factor 0.786 exceeded the existing 0.5 threshold.
The updater initially hit a lock error, then its startup integration fixture timed
out under load. The successful reruns used one test thread while engine testing
was stopped. No assertion, deadline in these tests or performance threshold was
changed. Swift initially crashed before running tests; a fresh build passed and
the ordinary `swift test` command subsequently passed too.

The first engine campaign exposed a real partial-cleanup retry regression from
the shutdown fix. It was stopped, the regression was fixed and the complete
campaign was restarted in four isolated clones at `a6f1c1c1`. The interrupted
campaign and its incomplete receipts are not counted as passing coverage.
The final campaign uses the official one-based shard interface, isolated homes
and a three-hour per-unit ceiling. Mutation campaigns are enabled throughout.

That complete run found one further test-harness defect: two container mutations
referenced the old reaping call and could not apply. Its 19 behavior tests passed.
The original failed receipt is retained. Only `containers.mutation.sh` changed
in the correction; the complete container unit then passed at `0f3d25bd`, with
a separate official coverage check. The [source comparison](repo-audit-third-pass-recheck-2026-09-16/container-harness-change.json)
confirms that all other files are unchanged at the merged revision. Receipts from
different revisions are kept separate; no failed receipt is relabeled as a pass.
The official verifier certifies the explicit unchanged set of 140 units at
`a6f1c1c1` and the corrected container unit at `0f3d25bd` separately. The original
141-unit receipt check correctly rejects the old container failure and is also
preserved. Together the two passing sets cover the complete unchanged inventory.

The longest unit took about 91 minutes. The coverage checks reported 22 execution
cost estimates above their stored weights. Those estimates were not rewritten
from a concurrent local run; the drift does not change which tests ran.

[Committed evidence](repo-audit-third-pass-recheck-2026-09-16/README.md) includes
the check summaries, original failed-attempt results, reproduction outputs and
engine receipts. Full local logs are under `/tmp/richos-audit3-recheck`,
`/tmp/richos-audit3-fixes` and `/tmp/richos-audit3-final-engine`.

## Scope

Verification ran locally on macOS. Windows compilation and portable tests do not
establish Windows runtime or WASAPI behavior. Live account ingestion, actual call
capture and a signed production release were not exercised. The previously
documented Windows recording-location issue remains outside these four findings.
The intentional remote CI pause was left unchanged.
