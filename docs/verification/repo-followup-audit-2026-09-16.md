# Repository follow-up audit, 2026-09-16

Audited revision: `2c1a48463da1d2028dfec958ff49924bab33828c`.

Follow-up: all four findings were repaired after this audit. See the
[repair and recheck report](repo-followup-audit-fixes-2026-09-16.md).
The findings and reproductions below describe the pinned audited revision.

Four defects remain: two P1 privacy boundary failures and two P2 reliability
failures. Each was reproduced against a pinned source archive using synthetic
data. Product code was not modified. These findings describe the current source;
they are not claims that every defect was introduced by the latest refactors.

The review examined the recent voice consolidation and nightly release changes,
then traced Loro reads and mutations, desktop correction calls, ECS scope and
receipt handling, worker integration, process ownership and service recovery.
Earlier audit reports and repairs were read to avoid reporting already fixed
issues. The newly reproduced cases below are distinct from those repairs.

## 1. P1: Superseding a private record bypasses the scope-widening guard

Source: [writer.js:307](../../richos/engine/loro/writer/writer.js#L307).
Desktop caller: [correction.rs:240](../../richos/app/crates/richos-core/src/correction.rs#L240).

`supersedeRecord()` preserves the company partition but forwards `opts.scope`
directly into `appendRecord()`. It never applies the `isWidening()` check used by
`correctRecord()`. The contract requires `--widen-scope` for widening visibility.
The desktop intentionally never emits that flag, but its `Supersede` request
still accepts and forwards a scope, making this reachable through that caller.

**Reproduction:** Append a CEO-private synthetic acquisition budget. Correcting
its scope to `org-shared` fails with exit 5. Superseding it with an `org-shared`
replacement, without `--widen-scope`, succeeds with exit 0. Compiling a worker
slice then returns the replacement. Company partition preservation does not
protect the separate audience boundary.

**Fix:** Check the replacement scope against the original scope before either
file is written. Apply the same explicit widening rule to every replacement
path. Test both the CLI and the desktop writer arguments, including a worker
slice proving that an unacknowledged widening did not happen.

Evidence: [probe](repo-followup-audit-2026-09-16/loro-scope.mjs),
[result](repo-followup-audit-2026-09-16/loro-scope.json).

## 2. P1: A linked page can turn private prose into shared context

Source: [sources.js:120](../../richos/engine/loro/lib/sources.js#L120).
File discovery: [sources.js:90](../../richos/engine/loro/lib/sources.js#L90).

The reader admits `.md` symlink entries and follows them with `readFileSync()`.
It derives privacy and company attribution from the lexical location of the
link. The recent writer boundary repair does not cover this reader path.

**Reproduction:** Put synthetic confidential prose in
`ceo/pages/private/acquisition.md`. A worker query correctly returns no records.
Create `ceo/pages/budget.md` as a symlink to that same private file. The identical
query now returns its complete prose as `org-shared`, attributed to the shared
alias. No content or scope in the private source was changed.

**Impact:** This requires an existing filesystem alias, such as one created while
organizing the corpus. It is not a demonstrated remote exploit. Once the alias
exists, the compiler itself misclassifies private content and its final scope
check accepts the incorrect classification.

**Fix:** Validate physical read paths before assigning privacy or company scope.
Reject descendant redirects across privacy/partition boundaries and outside the
corpus, or retain the strictest physical-source scope. Cover linked leaf files
and linked source-directory roots, as well as ordinary private pages.

Evidence: [probe](repo-followup-audit-2026-09-16/loro-read-links.mjs),
[result](repo-followup-audit-2026-09-16/loro-read-links.json).

## 3. P2: Concurrent replacements leave two conflicting records current

Source: [writer.js:291](../../richos/engine/loro/writer/writer.js#L291),
[writer.js:331](../../richos/engine/loro/writer/writer.js#L331).

The superseded check reads the corpus snapshot loaded by each CLI process.
There is no lock or conditional update spanning that check and publication of
the replacement and original record. Atomic individual file writes do not
serialize the multi-file operation.

**Reproduction:** Start two actual `loro-write supersede --body-stdin` processes
against the same original record. Both load the corpus and wait for their body.
Complete the first write, then supply the second process's body. Both commands
return success. The original now points only to replacement two, while both
replacement one and replacement two have `supersededBy: null` and remain current.
A third, sequential request is correctly rejected, confirming that the failure
depends on overlapping reader snapshots.

The probe's preload module only signals entry to stdin reading. It does not
alter reads, write behavior, source files or record contents. The reproduction
establishes a writer-level concurrency defect; it does not claim that two
confirmations inside one desktop correction desk execute simultaneously.

**Fix:** Serialize mutations across processes and reload/check the original
inside the lock. Protect both sides of supersession as one recoverable operation.
Test simultaneous replacements with different new IDs and require one refusal
or one valid supersession chain, never two contradictory current records.

Evidence: [probe](repo-followup-audit-2026-09-16/loro-concurrent.mjs),
[stdin observation hook](repo-followup-audit-2026-09-16/observe-stdin.mjs),
[result](repo-followup-audit-2026-09-16/loro-concurrent.json).

## 4. P2: One damaged recording aborts every watcher sweep

Source: [watcher.js:82](../../richos/tools/richos-service/lib/watcher.js#L82).
Outer recovery: [watcher.js:154](../../richos/tools/richos-service/lib/watcher.js#L154).

`scanZone()` has no exception boundary around an individual session. An I/O
exception from `audioBytesOnDisk()`, or a refusal from the pipeline's initial
`assertPrivateTree()`, exits the entire loop. `watch()` catches only around the
whole scan and retries the same inventory, so sessions later in enumeration
remain unprocessed while the bad entry remains.

**Reproduction:** A zone containing one healthy completed session returns that
session normally. Add an earlier session with a dangling `audio-part-0.wav`
link. Two consecutive scans both throw `ENOENT` instead of returning a
per-session anomaly and proceeding. Replace the dangling audio with an ordinary
file and add a linked transcript output: processing mode now aborts with
`storage boundary: output must be a regular unlinked file`. This also exercises
the newer storage refusal, without invoking speech models or native audio tools.

**Fix:** Catch failures per session, retain its anomaly and continue scanning.
Preserve the storage refusal. Do not turn a rejected output path into permission
to write an error receipt through it. Add a bad-session-plus-good-session test
in both reporting and processing modes.

Evidence: [probe](repo-followup-audit-2026-09-16/watcher.mjs),
[result](repo-followup-audit-2026-09-16/watcher.json).

## Validation

Tests ran against an archive of the exact revision, separate from the working
checkout. The four defect probes were then rerun from another fresh archive
using the reproduction driver below.

| Check | Result |
| --- | --- |
| Rust core, integration tests and doctests | 1,031 passed, 4 ignored |
| Tauri desktop shell | 98 passed |
| Rust voice, including synthetic speech acceptance | 225 passed, 4 ignored |
| User updater | 40 passed |
| Shared JavaScript voice tests | 35 passed |
| Service transcription tests | 329 passed |
| Service consumer subset | 3 passed |
| Workspace | 91 passed on corrected-home retry |
| Browser extension | 66 passed |
| Loro | 207 passed, 13 write-boundary checks and relocation passed |
| ECS | 18 passed |
| Desktop work adapter with synthetic Git worktrees | 13 passed |
| Provider supervisor | 1 passed |
| Nightly planner and local runner | 19 and 11 passed |
| Full voice consumer conformance, including Rust | 4 passed |
| Voice relocation | 4 passed |
| Python, shell and JavaScript syntax | 121 Python, 360 shell and 210 JavaScript files passed |

The initial aggregate service invocation passed its transcription tests but the
Workspace portion had four assertion failures: the archive was outside the
user's home, so the correct outside-home refusal preceded the product-boundary
message those tests expected. Running the unchanged Workspace suite with a
synthetic home containing the archive passed all 91 tests. Both logs are retained.
This is the same fixture-location constraint documented by the preceding audit.

Counts and raw-log SHA-256 digests are in
[check-counts.json](repo-followup-audit-2026-09-16/check-counts.json).
Syntax results are in [syntax.json](repo-followup-audit-2026-09-16/syntax.json).
Raw suite logs remain at the `/tmp/richos-audit-current-*.log` paths recorded in
that inventory and can disappear through ordinary temporary-file cleanup.

From the repository root, reproduce all four defects with:

```sh
python3 docs/verification/repo-followup-audit-2026-09-16/reproduce.py
```

The driver archives the pinned commit into a disposable directory. It needs Git,
tar and a recent Node runtime. Its assertions expect the defects, so a successful
run is evidence of the findings, not evidence that repairs pass.

## Limits and working-tree impact

No release was built or published and no live provider assignment was dispatched.
Full engine mutation coverage, full browser UI coverage, signing/notarization,
installed-app acceptance, live-account flows and Windows capture were not rerun.
Dependency advisories were not refreshed. Passing source tests do not establish
those properties or prove the repository is otherwise defect-free.

The main checkout remained at the audited revision. Existing `.DS_Store` files
were left alone. Only this report and its reproduction evidence were added to
the checkout. No product fixes, commits, merges or pushes were performed.
