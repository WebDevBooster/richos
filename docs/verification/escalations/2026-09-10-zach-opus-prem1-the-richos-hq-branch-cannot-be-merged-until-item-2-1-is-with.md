# Escalation: The richos-hq branch cannot be merged until item 2.1 is withdrawn or given a reason — by design, and it is one edit

- id: `esc-20260910T090506Z-82aff0fb`
- raised: 2026-09-10T09:05:06Z
- from: zach-opus-prem1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-prem1` (branch `zach-opus-prem1`)
- head: `1277da1b1d78fe5a1f55ae2bc2c6940206ce4dff`
- state: **work-complete**
- for: lead

## The question

Item 2.1 (verify the podcast reference transcript) claims it buys the first computable word error rate in this project; that stopped being true when WER was computed twice without it and section 10 was ruled on 2026-09-10 without it. Do you withdraw it to section 3 the way you withdrew 1.3 the same day, or does it stay in his column with a reason you will defend?

## What was already tried

The switch is on, with six of seven items warranted from their own artifacts. Measured, quoting the command: engine/scripts/row-currency-lint.sh on my richos-hq worktree exits 1 with 'PREMISE CENSUS ... evaluated=7 pinned=7 ... unstated=1' and 'BLOCK item 2.1 - PREMISE-MISSING'. The commit guard matches merges as well as commits, fires in the main checkout, and has no live override by design, so the merge is refused while 2.1 stands. The brief told me to leave an unjustifiable item failing rather than invent a premise for it, and I did. Row 3.21 also reads stale from my worktree; that is my stale cut, already fixed on richos-hq main at 012c6ef0, acknowledged.

## Proceeding meanwhile

Everything else is committed and verified: the premise check on the question tool (suite 19 of 19 including a live replay of all 85 real questions, 8 mutants all load-bearing) and the six warranted items.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T090506Z-82aff0fb`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T090506Z-82aff0fb --disposition "<what you decided or did>"
