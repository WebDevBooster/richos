# Revision 6: verification and review handoff

Branch: `codex/owned-outcome-completion`. Base: `d8afbc1f`.
Worktree: `/Users/alex/ab/richos-wt/codex-owned-outcome-completion`.

The R5 restart blockers are corrected: real ownership transitions get one
immediate reconciliation, and withheld unfinished work has exact process
diagnostics, a host wake and automatic liveness rechecks. See
[REVISION-6.md](REVISION-6.md) for the implementation and limits.

## Findings addressed

| R5 finding | R6 correction |
|---|---|
| F1 / C7: inherited hour-long dispatch refusal | A durable ticket permits one immediate inspection per actual ownership/process transition. Counters remain intact; duplicate startup callbacks cannot refill the allowance. |
| F2 / C8: silent recovery withholding | Persist exact owner/blocker identities, display them in both hook channels and wake an empty replacement without a paid audit. Existing asynchronous hooks watch for later exit and retry pickup in the same replacement. |
| F3: legacy process-start string mismatch | Parse both observed timestamp layouts and compare UTC instants. Invalid or changed times do not establish ownership. |
| F4: native executable assumption | Document an actual `claude` ancestor as a hard requirement. An npm runtime visible only as `node` remains unsupported. |
| F6: misleading brief diagnostic | Record `brief_correction` separately from `unverified`; accept prose punctuation around the same embedded assignment reference without weakening the exact first-line selector. |
| C4: sidecars at land | Actual installer rerun in an isolated copy with matching final library hashes and unchanged production pointer. Installation from the stable checkout is still required at land. |

Review during implementation also caught completed/empty same-ID sessions being
reopened and a process-lookup error bypassing the observer's tool fence. Both
are corrected and have regression coverage. A failed enrolled ownership check
now denies execution; unrelated optional observation failures keep their previous
behavior. This does not grant any new permission.

## Executed checks

| Check | Result |
|---|---|
| Native adapter suite | 119 tests passed on final adapter `2b29c6ef…`. Includes transfer reservation, failure and concurrency cases, same-ID observer restrictions, later-exit watching and actual CLI lookup-failure/timeout denial. |
| Cached dispatch suite | 33 tests passed. |
| Independent actual-process integration | 3 cases, 44 checks passed. Actual OS identities and shipped hook CLI; scripted leader actions and fake inspector, zero provider calls. |
| Independent implementation-peer review | 32 recovery tests passed and the final CLI ownership-failure test passed with both failure variants. These are subsets of the native total, not additional test inventory. No remaining finding in that bounded review. |
| Engine guard and mutation suite | 67 cases and 27 mutation properties passed, exit 0. Both changed library hashes stayed unchanged throughout the final run. |
| Disposable installer | Exit 0, all three owned-work sidecars match final sources, production pointer unchanged. No launchd job loaded. |
| Actual native registry probe | One live registry owner matched after date parsing, using read-only process inspection. No real process was signaled. |
| README claims check | All six checks passed. Rust inventory is unchanged. |

No Rust or UI runtime source changed in R6. The prior Rust and UI results remain
in [RESULTS-5.md](RESULTS-5.md); they were not relabeled as newly executed R6 tests.
No paid model trial was run for this revision.

## Process-level acceptance

The [original final result](evidence-r6/integration-final/result.json) records:

| Scenario | Measured behavior |
|---|---|
| Fresh session, exhausted budget | Real old owner terminated. New process received no assignment. Reconciliation began and returned in 0.186 seconds despite the saved 3,000-second delay. |
| Same session ID, exhausted budget | Real old owner terminated and replacement resumed its history. Reconciliation returned in 0.093 seconds with no new assignment. |
| Dead leader with surviving group member | A real disposable `sleep` retained the dead leader's PGID. Ownership stayed withheld and both notification channels named the process. The next Stop hook remained outstanding without an inspector call. After the scripted test action terminated only that exact fixture process, the same hook picked up the assignment and reconciled in 5.324 seconds, within the declared five-second poll plus three-second transport margin. |

Each case invoked exactly one fake inspector, consumed its transfer credit once,
retained the inspection count at six and preserved the original constraints.
Repeated startup/Stop callbacks did not buy another inspection. All fixture
process groups were empty afterward. The actual user's Claude processes were
only read for the registry probe and were never terminated.

The straggler removal was a **scripted test action**, not a model decision or an
adapter kill. This proves the process/notification/reconciliation mechanism. It
does not establish that a live model autonomously diagnoses every possible
surviving process. R5's real-provider trials retain their original source hashes.

## Preserved preliminary results

The first process run passed both direct restart cases and all straggler
mechanics, but its overall result was false: the harness incorrectly imposed the
direct restart's four-second limit on a five-second polling path. That original
false result is preserved under `integration-first`, along with the exact tested
harness and the matching adapter recovered from the immutable first installer
copy. The corrected harness explicitly allows eight seconds for that path.
The final run exercised all three cases against the final source. No original
result was rewritten and neither run called a provider.

The first engine run returned exit 0, but source identity changed while it was
running because the final ownership-failure correction landed. Its verification
wrapper therefore returned nonzero rather than calling that a frozen-source
pass. Its log and identity record are retained. The final run is recorded
separately.

## Reproduction and evidence

From this checkout:

```sh
python3 engine/scripts/lib/owned-session.test.py
python3 engine/scripts/lib/owned-dispatch.test.py
python3 app/scripts/test-owned-recovery.py
bash engine/scripts/hooks/ceo-asks.test.sh
python3 docs/verification/owned-outcome/evidence-r6/install-check.py
python3 docs/verification/owned-outcome/evidence-r6/verify-evidence.py
```

The process test requires a C compiler for its explicitly named `claude`
process-identity fixture. That small executable is not the Claude product and
does not contact a provider. The installer fixture accepts `--repo` and defaults
to the checkout containing it, so another review worktree can reproduce it.

Final adapter SHA-256:
`2b29c6ef6447c213da17d28b856caed4d72f9fdf9d05c3e63024b73c4152e178`.
Process acceptance harness SHA-256:
`6f94e22d5bc96366b7afb322ccbc88b1adcea0f49b1124f684f3f055d4c1f156`.

The artifact index maps original files to byte-identical copies with sizes and
hashes. Public integration receipts explicitly label selected/redacted user
permission context; their original hook outputs and inspector inputs are retained
privately, not discarded. The index maps those originals into
`/Users/alex/.codex/artifacts/richos-owned-outcome-r6-2026-09-09` with private file
permissions. The verifier checks those copies and final source hashes. Its
`--public-only` option explicitly reports skipped private evidence for a reviewer
without that local archive.

## Remaining limits and activation

No merge, push, production installation or workspace adoption occurred. The
changes are ready for review in their separate worktree. The stable checkout
still needs the installer run at land.

A same-ID recovery observer allows only `Read`, `Glob` and `Grep` while the old
group can still act. It cannot terminate a persistent residual process with Bash;
its notice says so. Automatic watching handles later exit. Fresh-session
diagnosis retains the normal permitted tools. No blanket kill or new permission
policy was added to remove that fence.

Native free-form prose still has no universal zero-trivial-question guarantee.
Compatibility enforcement and the narrower same-ID process-management capability
are recorded separately in [IMPROVEMENTS.md](IMPROVEMENTS.md). The process fixture
is not evidence that these separate limitations have disappeared.
