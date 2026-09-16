# Follow-up audit repairs and recheck, 2026-09-16

The four findings in [the follow-up audit](repo-followup-audit-2026-09-16.md)
were fixed, merged individually and pushed to `main`. The audit documents and
historical defect reproductions were committed and pushed first as `90f1d2a3`.
Those reproductions remain pinned to the defective revision.

| Repair | Implementation | Merge |
| --- | --- | --- |
| Require explicit scope widening for Loro replacements | `4ea4e47d` | `0933a0a3` |
| Validate physical Loro read boundaries before assigning visibility | `99495824` | `6ea77438` |
| Serialize Loro mutations and reload records inside the lock | `5495f6e2` | `93e43928` |
| Keep refusal tests out of checked-in corpus fixtures | `a56706db` | `4c9b6966` |
| Isolate recording watcher failures per session | `c2005573` | `d9cac993` |
| Repair a stale model-cost citation exposed by the publication gate | `eedf4e97` | `0ab3c371` |
| Update the documented Rust count for the new regression | `8106ef54` | `392cd70a` |
| Drain brief-scope diagnostics before evaluating assertions | `483d5410` | `9842c1bb` |

## Repaired behavior

A superseding record now uses the same explicit `--widen-scope` rule as a
correction. Every widening combination is refused before record publication
unless acknowledged. Tests cover actual writes, previews, unchanged source
records and worker visibility. The real desktop writer is also tested: its
preview and commit both refuse a wider replacement, while a private replacement
succeeds.

Loro validates the physical paths of sources before attributing scope or
company. Descendant symbolic links and multiply linked files are refused,
including linked source roots, manifests, entity indexes and record files.
Regular private pages retain their private scope. A safe alias of the selected
corpus root still works. These checks cover existing filesystem redirects;
they are not an OS sandbox against an adversary replacing ancestor directories
concurrently.

All Loro mutation entrypoints now use one cross-process lock per corpus.
Corrections, replacements and citation relinks reload the source under that
lock. SQLite supplies OS-managed locking through the delivered Node runtime,
without an npm dependency. Lock contention has a five-second bound and a
clear retry refusal. The persistent lock file is never deleted as a stale-lock
heuristic, and process death releases ownership. Tests cover the original
overlapping CLI snapshots, stale scope decisions, equivalent root aliases,
contention, killed writers, linked SQLite sidecars and previews that create no
files. The tests also passed on the delivered Node 24.21 runtime.

The writer lock addresses concurrent mutations. It does not make the two
filesystem publications in supersession a crash-atomic transaction. Killing
a writer between those publications can still require recovery. No such
transactional guarantee is claimed by this repair.

The recording watcher catches failures around each session and records an
anomaly before continuing. Tests repeatedly place a broken recording before
a healthy one in reporting and processing modes. A refused output path remains
refused: the watcher writes no error receipt through it and still reaches the
next pending pipeline.

## Reproduction and verification

Run the permanent regressions with:

```sh
python3 docs/verification/repo-followup-audit-fixes-2026-09-16/recheck.py
```

The driver checks for the named regressions and positive summaries as well as
successful exit codes. All fixtures are synthetic. The original audit driver
continues to reproduce the historical defects and should not be used as the
repair acceptance check.

Verification began on September 16 and completed on September 17. The final
implementation and test revision is `9842c1bb`; subsequent changes only record
the verification results.

| Check | Result |
| --- | --- |
| Rust workspace, integration tests and doctests | 1,257 passed, 8 ignored |
| Tauri shell | 98 passed |
| User updater | 38 unit tests and 1 integration test passed; its subprocess check also passed |
| macOS companion | 41 passed |
| Windows companion core and Release build | 26 passed; build passed |
| Shared JavaScript voice | 35 passed |
| Service transcription and consumer subset | 331 and 3 passed |
| Workspace | 91 passed |
| Browser extension | 66 passed |
| Service mutation audit | 56 mutations detected across 41 audited checks |
| Five service E2E suites | All passed with named optional skips |
| Full browser inventory | 35 suites, 572 checks passed, 0 skipped |
| macOS packaging inventory | 12 suites, 181 checks passed |
| Engine non-suite verification | All 6 steps passed |
| Full engine inventory | 148/148 units covered, including the repaired brief-scope suite |
| Loro | 208 core checks, 13 write-boundary checks, 10 read-boundary checks, relocation and concurrent-writer checks passed |
| Four audit regression groups | Loro scope, read-boundary and writer-concurrency tests; desktop 5 tests; watcher regressions all passed |
| Tracked-file syntax | 419 Python, 505 shell, 176 JS and 71 MJS files passed |

The native, service, companion, packaging and engine inventory runs use
`d9cac993`. The full browser rerun and non-suite engine rerun use `392cd70a`.
Their production source trees are identical. The intervening changes only
repair the stale citation and documented test count. The brief-scope repair
was checked separately at `483d5410` before its merge. Source identities and
raw log hashes are retained with the evidence.

The full engine run at `d9cac993` passed 147 units and exposed the brief-scope
assertion failure. Its original canonical receipt verifier correctly refuses
that run. The entire repaired unit then passed at `483d5410`, including all
11 mutations and the checkout canary. The other 147 units are unchanged.
The [coverage ledger](repo-followup-audit-fixes-2026-09-16/engine-coverage.json)
reconciles every discovered unit with its original result and any repair
rerun. It is not a single-revision CI certificate. No failed receipt was
rewritten or silently discarded. The longest unit completed all 85 workspace
mutations, all 14 lifecycle checks and its own cleanup check.

The [check records](repo-followup-audit-fixes-2026-09-16/checks.json),
[source identities](repo-followup-audit-fixes-2026-09-16/source-identities.json),
[browser coverage](repo-followup-audit-fixes-2026-09-16/browser-coverage.log)
and [regression results](repo-followup-audit-fixes-2026-09-16/regressions/results.json)
record the exact commands, revisions and outcomes. Raw suite logs remain at
the paths in the check records; their SHA-256 digests are retained in Git.

The first Linux launcher stopped before testing because its container could
not create `/repo`; the corrected launcher uses `/tmp/repo`. An initial repair
runner argument and an output-label mismatch in the new regression driver
were also corrected and rerun. Their failed attempts remain in the evidence.
The reused runtime initially failed its file inventory because Python cache
files had changed. A fresh extraction passed runtime verification against the
tracked recipe; its manifest was not rewritten. Packaging used that verified
runtime with Python bytecode writes disabled.

The first publication-completeness run found a hardware document pointing to
the model-cost table at its pre-refactor location. Its citation now names
`richos/engine/voice/models/model-costs.json`, and all six non-suite engine
verification steps pass. The browser documentation gate also required the
Rust test count to include the new desktop regression. After that correction,
all 35 browser suites passed with 572 checks and no skips at `392cd70a`.

The full engine run exposed another early-exit pipeline in the brief-scope
test harness. Its output contained `SPEC-SATISFIED`, but `grep -q` could close
the pipe before `printf` finished, causing `pipefail` to report a missing
message. A large-output regression failed on the old assertion. The helper
now consumes the entire diagnostic, and an absent-marker control still fails
as required. The complete suite and all 11 mutation checks passed on macOS and
Linux. This changes the test harness, not the production scope guard.

## Limits and remaining follow-up

The existing moderate Linux `glib` dependency advisory remains open. No
dependency was changed and the alert was not dismissed. The earlier
[dependency analysis](repo-audit-post-refactors-fixes-2026-09-16.md#open-dependency-advisory)
explains why a lockfile-only bump is insufficient.

No live Windows capture, live provider authorization, paid doctrine-sentinel
turn, personal corpus test, microphone/output-device acceptance, signing,
notarization or nightly installation was performed. The service E2E suites
retain their named optional-memory, Windows-surface and large-v3-model skips.
The GUI boot suite declares its existing vocabulary-service installation gap.
The no-certificate packaging branch cannot run on this host because a Developer
ID identity is present. The brief-scope suite's optional cross-repository
provenance comparison cannot run inside Linux; its pinned acceptance fixture
and behavioral cases do run.
Passing local tests does not establish those external integrations or prove
that no other defects remain.

Raw logs and disposable checkouts are retained at
`/Users/alex/ab/richos-rechecks/followup-20260916`. Existing untracked
`.DS_Store` files and unrelated worktrees were left untouched.
