# Escalation: Item 1 is NOT purely obsolete: 6472bb60 also broke the rollback branch deletion in its fallback path, and rollback then reports success anyway

- id: `esc-20260908T182811Z-7d1a359b`
- raised: 2026-09-08T18:28:11Z
- from: zach-opus-ob1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ob1` (branch `zach-opus-ob1`)
- head: `e457eab6826c108bd1dc300f6569e5dcce6501d0`
- state: **proceeding**
- for: lead

## The question

May I edit engine/scripts/create-teammate-worktree.sh (outside my allowlist, uncontended - all 9 live worktrees byte-identical) to replace the removed bulk prune with a TARGETED deletion of only this tree admin registration, plus a C21 case and a fifth mutant? Or do you want that as a separate task?

## What was already tried

Reproduced in a throwaway repository. When the removal command inside rollback fails and the fallback directory delete runs instead, the following branch-delete line is REFUSED with 'cannot delete branch used by worktree at ...' rc=1. That line ends in a swallow, so rollback still prints 'ROLLED BACK: the worktree and the branch were removed again' - which is false; branch and stale registration both survive. The same probe confirms 6472bb60 own concern is real, and that deleting only this tree admin directory makes the branch delete succeed while leaving the unrelated registration intact.

## Proceeding meanwhile

Re-pointing the no-rollback mutant at the primary rollback path, which is correct and merely moved, and doing item 2 (Layer Q fixture) in full.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260908T182811Z-7d1a359b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260908T182811Z-7d1a359b --disposition "<what you decided or did>"
