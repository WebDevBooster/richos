# Audit fixes and post-merge verification

The five findings in [the September 16 audit](repo-audit-2026-09-16.md) were fixed,
tested, merged individually into `main` and pushed to `origin/main`.
A second source review found two more corpus-path bypasses: a missing directory
followed by `..` could expose an unresolved alias, and the ancestor search stopped
after twelve levels. Both were reproduced and closed in one additional merge.
A later filesystem probe also showed that the Node path resolver preserved
case-equivalent spellings on this Mac. Switching to its native resolver closed
that bypass. Swift already used the native resolver; a new test confirms parity.
Final product code revision: `734d06f61a5b309b14796a8e35fc5484e9dea0cf`.

## Changes

| Finding | Fix commit | Merge commit | Regression evidence |
| --- | --- | --- | --- |
| Corpus provisioning followed aliases into the product checkout | `7d956725` | `3d69315e` | An alias into the checkout is refused before creation; external aliases remain valid; unresolved links are refused |
| macOS capture accepted aliased recording paths into the checkout | `06bf8c97` | `570378ce` | The public resolver checks physical destinations before capture; all 40 Swift tests pass |
| Explicit CLI session paths bypassed the evidence boundary | `08f624d1` | `4ea1f124` | Both `run` and `retranscribe` refuse direct and aliased product paths without changing session files; external sessions still process |
| Native-host reinstallation retained old paths | `d98b1e71` | `0f006136` | After moving both host and Node, repeated installation produces a launcher that runs; shell metacharacters and JSON paths round-trip |
| Dispatcher rule failures were invisible on the host channel | `57e33e3c` | `ae7235b7` | All 36 behavior checks and 18 mutation checks pass; missing, crashed and unstarted rules produce visible notices |
| Compound aliases and deep paths bypassed corpus checks | `b6728b28` | `c2112510` | Both regressions failed before the fix; all 25 provisioning tests and the full core suite passed afterward; the README count was updated |
| Case-equivalent paths bypassed the service boundary | `1ca304ac` | `734d06f6` | The new case test failed before the fix; both CLI commands now reject alternate casing; 335 service checks, 73 Workspace checks and 41 Swift tests pass |

Each defect regression failed against its unfixed implementation before the fix was
applied. The dispatcher keeps the existing nonblocking policy and preserves a
single sibling envelope's decision and context. Its Bash fallback still reports
failures when the JSON encoder cannot run; if that prevents preserving sibling
output, the notice explicitly says so. Existing multiple-emitter collisions
remain explicitly reported rather than silently concatenated.

The final [audit reproductions](repo-audit-recheck-2026-09-16/reproductions.json)
show that all five original failure cases are resolved. The installer probe now
uses a self-contained host stub so a moved-launcher success is independently
observable. The original defective-behavior receipt remains unchanged.

## Completed verification

| Area | Result |
| --- | --- |
| Core and voice Rust workspace at `c2112510` | 1,216 passed including documentation tests; eight ignored |
| Desktop Rust at `c2112510` | 98 passed |
| Detached user updater | 38 passed; its filtered child invocation is not double-counted |
| macOS capture companion at `734d06f6` | 41 passed |
| Service and Workspace at `734d06f6` | 335 + 73 passed |
| Browser extension | 66 passed |
| Windows companion | Release build succeeded; all 26 portable core tests passed using .NET 8.0.424 |
| Packaging at `c2112510` | All nine suites passed, 178 checks |
| Browser UI at `c2112510` | All 31 suites passed, 554 checks and zero skips |
| Syntax | All 494 shell files, 379 Python files and 150 JavaScript files passed |
| Engine checks outside suites | All six steps passed in an isolated clone |
| Publication completeness | Passed |
| Full engine campaign | All 141 units passed across 118 discovered suites, including mutation campaigns; official receipt coverage verified |

All 24 tracked screenshots regenerated during each browser run were restored.
The eight ignored Rust tests remain unexecuted. The final workspace run used
`--test-threads=1`; the voice timing check passed with its original threshold.

[Committed evidence](repo-audit-recheck-2026-09-16/README.md) includes the receipts,
reproduction output and validation summaries. Full local logs are under
`/tmp/richos-recheck-20260916`; targeted regression logs are under
`/tmp/richos-fix[1-7]-*.log`.

The initial application run at `ae7235b7` had two failures: the voice synthesis
timing check exceeded its 0.5 real-time-factor threshold under concurrent load
(observed 0.808), and `docs-claims.js` caught the README total made stale by the
new Rust tests. The original failed results are retained. The README was fixed
in the corpus follow-up; no test assertion or synthesis performance threshold was changed.

The full engine campaign ran at `ae7235b7`. Its entire `richos/engine` tree is
identical at `734d06f6`; engine receipts retain their original tested revision.
The affected application suites were rerun at `c2112510`, and that complete
`richos/app` subtree is identical at `734d06f6`. The service and Swift suites
were rerun after the casing fix. These are verified source identities, not
rewritten receipts claiming that every command ran at the last commit. An
initial zero-indexed shard invocation selected no units and failed before
running any tests; it was corrected to the runner's one-based shard numbering.
No empty shard is counted as passing evidence.

The engine shards used a three-hour per-unit deadline so the full campaigns
could finish on the shared host. The longest unit took about 90 minutes. The
receipt verifier also reported 35 execution-cost estimates above their stored
weights; coverage still passed. CI weights were not rewritten from this
concurrent local measurement.

## Scope and remaining limits

This is local verification on macOS. Windows companion compilation and its
portable tests do not establish Windows runtime behavior or WASAPI capture.
Live account ingestion, actual call capture and a signed production release
were not exercised. Ignored tests remain exclusions, not passes.

The previously documented Windows recording-location defect remains outside
these five fixes. The intentional remote CI pause remains in place. GitHub
continues to report the pre-existing moderate dependency alert.
