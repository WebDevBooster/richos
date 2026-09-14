# Escalation: The landed record's passenger claim is false, and its inventory misses 2 merges / 20 commits

- id: `esc-20260914T070409Z-5622da32`
- raised: 2026-09-14T07:04:09Z
- from: reed-opus-cx2
- worktree: `/Users/alex/ab/richos-wt/reed-opus-cx2` (branch `cc/reed-opus-cx2`)
- head: `17726885e49f8f3e02e306fa4f62d1df74a4f393`
- state: **work-complete**
- for: lead

## The question

Should the landed record codex-branch-merge-provenance-2026-09-14.md be corrected in place, and should any ruling about codex work reaching main quote 38 operations and 185 commits rather than 36 and 165?

## What was already tried

Re-derived every count independently. The record's 165 reproduces exactly. Its inventory does not: it reads only reflog entries naming a branch, and is blind to the form written when a merge is finished by hand after conflicts, which records no branch name. Two such operations are absent from its tables: 727d8890 (codex/durable-orchestration, 16 commits) and 7714871a (Merge Codex 9/10, 6 commits). Its passenger claim rests on an ancestry test that is true of every later merge. Full evidence and every command in the committed record.

## Proceeding meanwhile

Work is complete and committed: docs/verification/codex-merge-reflog-inventory-2026-09-14.md on branch cc/reed-opus-cx2, commit 17726885. One row per merge, commands beside every number, UNDETERMINED count of 1, and before/after proof that nothing was mutated in any repository.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T070409Z-5622da32`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T070409Z-5622da32 --disposition "<what you decided or did>"
