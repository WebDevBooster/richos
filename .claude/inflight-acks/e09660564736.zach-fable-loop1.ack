sha: e096605647365d63156174c42cb82ce9126943da
impact: stale-record
detail: Tom's audit landed with fixes for F1-F3 (client-data suite 17/17 and no longer skipped, freshness exit 4, lint-banned refusal). Re-swept the real roots at the new tip: the ci-excluded-suite finding for client-data-check.test.sh is no longer produced (the sweep's GONE path is what would name its row); end-to-end proof switches to F5, the unrun mutation harnesses, which remain open (8 at the new richos tip, including waiver-repetition.mutation.sh). No file in my scope collides with the landed paths.
paths: docs/audits/tom-audit-never-ran-2026-09-02.md scripts/hooks/** scripts/tests/** scripts/lib/freshness-gate.sh
teammate: zach-fable-loop1
worktree: /Users/alex/ab/richos-wt/zach-fable-loop1
written: 2026-09-02T12:42:24Z
