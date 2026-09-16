# September 16 audit recheck evidence

See [the verification report](../repo-audit-fixes-2026-09-16.md) for the fixes,
results and limits. These files retain the actual tested revisions.

- `summary.json`: final coverage, test totals and the identical engine/application tree hashes.
- `engine/`: the four original engine receipts. All 141 units passed at `ae7235b7`.
- `inventory.tsv` and `engine-receipt-verification.log`: the complete planned inventory and the official coverage proof.
- `initial-runs.json`: original run outcomes, including the timing failure, stale README count and rejected empty shard invocation. These remain failures.
- `completed-runs.json`: application reruns at `c2112510`, service/Swift reruns at `734d06f6` and engine completion records.
- `reproductions.json`: all five original probes run against the final product code.
- `followup-affected-units.txt` and `followup-affected-mapping.log`: the strict engine selector maps the later application/service edits to no engine units.
- `syntax.json`, `environment.json` and `workflow-states.json`: syntax coverage, local tool versions and the unchanged remote CI pause.

The original engine receipts were not rewritten to claim execution at the later
application revision. The complete engine subtree is identical at the final revision. The complete
application subtree is identical between its tested revision and the final revision.
All mutation campaigns ran; the four engine shards used four mutation workers
each and a three-hour per-unit deadline. Test assertions and the synthesis performance threshold
were unchanged. Full logs remain under `/tmp/richos-recheck-20260916`.
