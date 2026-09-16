# Post-refactor audit fixes and full recheck, 2026-09-16

The six findings in [the original audit](repo-audit-post-refactors-2026-09-16.md)
were fixed, merged separately and pushed to `main`. The original audit evidence
remains unchanged. The broader recheck also exposed a stale GUI boot-log
classifier, addressed in a seventh isolated fix.

## Landed changes

| Finding | Implementation | Merge |
| --- | --- | --- |
| Pipeline output links bypassed the storage boundary | `3d75331a` | `13ce5bb0` |
| Workspace evidence descendants bypassed the storage boundary | `cf129f57` | `9f8f7bd7` |
| Torn JSONL tails swallowed the next accepted ingest record | `d9185744` | `8cab5721` |
| Sanitized evidence identities overwrote distinct revisions | `20d27f83` | `231cc01a` |
| Calendar cursors and source IDs lacked account/calendar scope | `7475bdc8` | `ddd5e27e` |
| Unexpected analyzer failures reported healthy or recovered | `aa944282` | `134ef73b` |
| GUI boot classifier rejected the window-placement diagnostic | `a114a673` | `17832025` |

The audit documents were committed and pushed first as `cee3e96c`.

Pipeline outputs are checked before processing. Existing symlinks and hardlinks
are refused. Native ffmpeg and Whisper outputs are staged in private directories
before publication. Workspace directories and all revision files receive the
same boundary checks.

Both JavaScript ingest logs preserve a torn tail, add a separating newline and
flush the next accepted record. A fresh reader can find that record immediately.

Evidence paths hash the full source ID and opaque etag. A repeat observation
does not rewrite evidence; conflicting content for one identity is refused.
Complete revisions are published from staging. Existing legacy citation paths
remain valid when their complete stored identity matches.

Calendar adapters require an explicit stable account identifier. Account and
calendar together scope item IDs and sync cursors. Legacy unscoped cursors are
retained as history and retired before a scoped full sync. Callers must bind
`accountId` to the authenticated account, never to a rotating access token.

The stated-action wrapper still allows a turn to end when the analyzer crashes.
It now reports that the check did not run and only reports recovery after a
successful evaluation. The new crash-reporting mutation is detected.

## Independent regression probes

The sibling `reproduce.py` and `service-probes.mjs` run only against disposable
copies and synthetic input. They assert all six repaired behaviors and exit
nonzero on regression. The original before-fix probes and results are preserved
in the original audit directory.

```sh
python3 docs/verification/repo-audit-post-refactors-fixes-2026-09-16/reproduce.py
```

The earlier first-pass and third-pass audit reproductions were also rerun. All
nine earlier findings retained their repaired behavior.

## Full recheck

The seventh fix was separately tested by the complete packaging inventory at
`a114a673`. Its merge `17832025` changes only
`richos/app/scripts/gui-boot.test.sh`. The engine tree at `134ef73b` and `17832025` is identical (`c20664847227e8861f68b9471c89dd18e63681d1`).

The first six fixes were tested together at
`134ef73b3a00f008bfd5e8c6306447d74cb423e1`. Engine verification uses the complete
142-unit inventory, including embedded mutation campaigns, with coverage
receipts tied to that commit. Coverage combines 44 macOS units and 98 Linux
units at the identical source revision. Native application tests ran from the
main checkout. Browser tests and service mutations ran in an isolated clone;
engine installation, probe and demo steps ran in a separate clone.

| Check | Result |
| --- | --- |
| Rust workspace: core and voice, including integration tests | 1,219 passed, 8 ignored |
| Tauri shell | 98 passed |
| User updater | 37 unit tests and 1 integration test passed |
| macOS companion | 41 passed |
| Windows companion core | 26 passed |
| Windows companion Release build | Passed, no warnings or errors |
| Service and Workspace | 365 and 91 passed |
| Extension | 66 passed |
| Service model-integrity mutation audit | 41/41 detected |
| Stated-action tests and mutation campaign | 49 passed; 32/32 detected |
| ASS Kicker relocation | 7 passed |
| Main transcription E2E | Passed, 1 optional-memory skip |
| Native-host E2E | Passed |
| Capture-coordination E2E | Passed |
| Cross-surface E2E | Passed on retry, Windows surface skipped |
| Accuracy-tier E2E | Passed, optional large-v3 model skipped |
| Tracked-file syntax | 386 Python, 495 shell and 197 JavaScript files passed (including follow-up probes) |
| Engine non-suite checks | All 6 steps passed |
| Browser UI | 31 suites, 554 checks, no skipped suites |
| Engine unit coverage | 142/142 passed, including complete mutation campaigns |
| macOS packaging | Full retry passed: 9 suites, 180 checks |

No assertion thresholds were relaxed. The engine's known-red table is empty.
The per-unit local deadline was 10,800 seconds. Mutation workers were bounded:
two per ordinary campaign and four for the large Linux workspace campaigns.
Some slow macOS campaigns were interrupted and replaced by complete Linux runs,
after the unchanged 76-test baseline passed there in 34 seconds versus 185
seconds on macOS. Interrupted units do not count as completed coverage. The
Linux image was already installed locally; no remote workflow was enabled or
dispatched.

The initial Linux container lacked an init process. The spec-fourteen fixture
waited before C12.4 for an orphaned synthetic session process that had become a
zombie. The unfinished container runs were stopped and rerun with Docker
`--init`, preserving only already completed PASS receipts. No test assertion was
changed to compensate for this setup error.

The [coverage verifier](repo-audit-post-refactors-fixes-2026-09-16/engine-coverage.log) certified exactly
142 planned units, all green at one source commit. The canonical
[receipts](repo-audit-post-refactors-fixes-2026-09-16/engine-receipts/complete.jsonl) retain the runner's records.
The four initial failed records and their passing replacements are linked in
[engine-retries.json](repo-audit-post-refactors-fixes-2026-09-16/engine-retries.json); raw receipts are retained
under `raw-engine-receipts`. No failed record was relabeled as passing.

[checks.json](repo-audit-post-refactors-fixes-2026-09-16/checks.json) records completed checks and retries.
[source-identities.json](repo-audit-post-refactors-fixes-2026-09-16/source-identities.json) ties the results to
source hashes and unchanged component trees. The local log manifest is
[logs.json](repo-audit-post-refactors-fixes-2026-09-16/logs.json). The shard verifier also reported 15 timing weights
that underestimated these runs. That affects scheduling, not coverage; the
mixed-platform timings were not written back as CI weights.

## Recheck failure and additional repair

The initial packaging run passed eight suites and failed `gui-boot.test.sh` B2.
The app successfully booted but its `[richos] window: derived ...` diagnostic had
no classifier rule. The healthy fixture also omitted that line, so its fast
self-checks did not expose the drift.

The repair requires a successful derived or restored placement with dimensions,
position and a display measurement. It updates the healthy fixture and covers
small displays, negative coordinates, restored placement and re-derivation after
a display disappears. A missing placement fails its own proof. Display query
failures, fallback placement and missing reasons remain explicitly refused.

The first cross-surface E2E run could not build the Swift companion and failed
its requirement to exercise at least two surfaces. The harness suppresses build
stderr, so the cause of that first build failure is unconfirmed. A direct
`swift build --jobs 2` succeeded without source changes or cache deletion. The
complete cross-surface rerun then passed through the extension and real macOS
companion. Both runs are retained in the check record.

Three Linux units correctly refused the sparse checkout because their fixtures
need product files outside the engine: the dialect guard and vendoring guard
need the real parent registry, and session evidence imports the application test
summary parser. All three passed unchanged against a full checkout at the same
commit. The original failed receipts are retained alongside their replacements.

The container-cleanup campaign also could not prove its Docker integration
properties inside the container without a Docker daemon. Its complete unit
passed on the macOS host with the real daemon and the local Alpine test image.
The incomplete Docker-free result is not counted as a pass.

## Open dependency advisory

GitHub still reports [GHSA-wrw7-89jp-8q8g](https://github.com/advisories/GHSA-wrw7-89jp-8q8g)
for `glib 0.18.5` in `richos/app/src-tauri/Cargo.lock`. The advisory describes
unsound mutation through an immutable pointer in `VariantStrIter`, with possible
crashes in optimized builds. Its first fixed release is `0.20.0`.

`cargo tree --locked --offline -i glib` reports no dependency on this macOS target.
The same command with `--target x86_64-unknown-linux-gnu` confirms it is pulled in
through GTK 0.18 and Tauri's Linux dependencies. This is an existing dependency
follow-up outside the six repaired findings. It remains open: the Linux GTK
dependency line needs a compatible upstream repair or a reviewed backport before
claiming that platform free of this advisory. A direct change to the lockfile's
glib version would not satisfy GTK's 0.18 dependency constraint.

The alert response and both dependency-tree outputs are retained beside this
report. This check inspected the reported advisory; it was not a full dependency
vulnerability scan. No dependency override or alert dismissal was made.

## Limits

Windows live capture cannot run on this macOS host. The Windows core tests and
Release build do not substitute for that integration check. No live Calendar
account, OAuth authorization or delivered-nightly installation was exercised.
The optional large-v3 model was absent. The main E2E suite did not load real
entity memory; synthetic correction fixtures were exercised. The existing
vocabulary-service installation gap remains declared by the GUI boot suite.

The intentional remote CI pause was not changed. Local logs and disposable
checkouts are under `/tmp/richos-fixes-20260916`. Existing untracked `.DS_Store`
files were left untouched.
