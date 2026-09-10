# Escalation: Dormancy cannot be declared: ci-surface.py has no dormant vocabulary, and it is out of my scope to add one

- id: `esc-20260910T090332Z-215366a2`
- raised: 2026-09-10T09:03:32Z
- from: zach-opus-dor1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-dor1` (branch `zach-opus-dor1`)
- head: `0159b5d36c581d5583731c83b004837e27ff29eb`
- state: **work-complete**
- for: lead

## The question

Two calls that are not mine: (1) should a declared-dormant / declared-known-red vocabulary be ADDED to ci-surface.py — and to whom, given I am scoped out of that file? (2) deeply's check/lint/test are red for 143 ESLint errors, 49 TypeScript errors and 7 svelte-check errors, plus a hanging 16px readability gate — is deeply still a product we spend on, and who fixes them?

## What was already tried

Enumerated every declaration vocabulary ci-surface.py reads: exactly three — ci-budget:, ci-skip:, ci-evidence: — and zero occurrences of dormant/archived/inactive. lib/ci-known-red.tsv looked like the mechanism but governs scripts/ci-units.sh verification units inside the engine's own shard runner, not GitHub workflows in adopter repositories, so it cannot carry a deeply or kit workflow. There is therefore no way to declare dormancy without editing ci-surface.py, which my brief forbids because another agent owns it right now.

## Proceeding meanwhile

All six workflows are classified with evidence and two are FIXED and verified end-to-end on Linux: claude-orchestration-kit/kit-self-verify (a BASH_CMDS reserved-name collision, red 51 days) and deeply/deploy-staging (a 2-minute budget that silently became impossible). A third, unasked-for defect was found and fixed: deeply's MODEL_TIERS was blank, so its spawn guard's clause 6 was failing OPEN. Branches are committed and unmerged; Rich lands.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T090332Z-215366a2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T090332Z-215366a2 --disposition "<what you decided or did>"
