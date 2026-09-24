# Escalation: §81 land check: the UNCOVERED refusal came from main's copy of proof-for.sh, not from a missing declaration

- id: `esc-20260924T005143Z-bd85c271`
- raised: 2026-09-24T00:51:43Z
- from: zach-opus-battery2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-battery2` (branch `cc/zach-opus-battery2`)
- head: `6c581418c3b2cfaa84b3ba7eaeb0c10592017c27`
- state: **proceeding**
- for: lead

## The question

Land zach-opus-battery2 with the branch's own runner (cd <worktree>/richos/app && scripts/proof-run.py main..HEAD), not the main checkout's copy — OK?

## What was already tried

Branch's own proof-for.sh main..HEAD exits 0 and says battery-check.py is 'behavior covered by battery-check.test.sh' and battery-check.test.py is 'wrapped by battery-check.test.sh'. The main checkout's proof-for.sh (d17008c9) reads suite declarations from its own scripts/ dir, where battery-check.test.sh does not exist yet, so it exits 1. No declaration change was needed.

## Proceeding meanwhile

Merged main into the branch (removes the host-cpu-enforcement doc from main..HEAD) and running the full land selection through the branch's proof-run.py.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T005143Z-bd85c271`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T005143Z-bd85c271 --disposition "<what you decided or did>"
