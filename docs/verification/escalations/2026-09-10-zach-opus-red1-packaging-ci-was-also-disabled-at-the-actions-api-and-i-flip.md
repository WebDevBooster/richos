# Escalation: packaging-ci was also disabled at the Actions API, and I flipped that OUTSIDE git — it will not arrive with the merge

- id: `esc-20260910T070437Z-68a74b04`
- raised: 2026-09-10T07:04:37Z
- from: zach-opus-red1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-red1` (branch `zach-opus-red1`)
- head: `a8289e5bcf0d7d74ad5fdb2ab0b8900e8d70b9d5`
- state: **work-complete**
- for: lead

## The question

Nothing needs deciding; this is the one part of the fix that no commit carries, so it needs to be known independently of whether zach-opus-red1 is merged.

## What was already tried

Diagnosed both dormancy causes and fixed both. The file's push/pull_request triggers are restored on the branch (commit 41182815). The repository SETTING was 'disabled_manually' at https://api.github.com/repos/WebDevBooster/richos/actions/workflows/346677481 and is now 'active' — I set it with gh api PUT on 2026-09-10. That is a GitHub setting, not a file, so it is ALREADY live on main and it survives the branch being dropped. Proof it mattered: while disabled, 'gh workflow run packaging-ci.yml --ref main' answered HTTP 422 'Cannot trigger a workflow_dispatch on a disabled workflow', so the file's own documented escape hatch had never worked. Green runs on the branch: 34446378461 (push), 34447223783 (dispatch), 34447761670 (push, final tip a8289e5b) — 8 of 9 suites, 147 checks, one declared host gap.

## Proceeding meanwhile

Consequence to expect at the land: once the branch merges, packaging-ci starts firing on every push touching app/**, engine/VERSION, engine/scripts/named-persons.*, LICENSE or its own file — roughly 4-7 minutes on macos-latest, free on a public repo. Until it merges it is active but triggerless on main, which is harmless. Separately: richos-hq/RICH-TODOs.md row c1 still says the Windows capture path is 'proven by neither CI nor hardware'; richos windows-companion-ci is active and green (34446415551 on my branch, 33901290800 on main), so that half of the row is stale.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T070437Z-68a74b04`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T070437Z-68a74b04 --disposition "<what you decided or did>"
