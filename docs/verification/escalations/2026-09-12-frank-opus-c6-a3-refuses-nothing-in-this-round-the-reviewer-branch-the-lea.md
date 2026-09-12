# Escalation: A3 refuses nothing in this round: the reviewer branch the lead cuts is itself the witness

- id: `esc-20260912T160559Z-9474bca5`
- raised: 2026-09-12T16:05:59Z
- from: frank-opus-c6
- worktree: `/Users/alex/ab/richos-wt/frank-opus-c6` (branch `cc/frank-opus-c6`)
- head: `86062927ceb0e6f309ca023f09ab40d3887879fd`
- state: **work-complete**
- for: lead

## The question

Should the next round treat a branch the lead cut at the engineer's tip as a witness for A3, given that it is the normal review handoff and it currently makes a self-signed retirement and a same-commit not-a-probe marker both exit 0?

## What was already tried

Reproduced three ways in a throwaway local clone at cc/zach-opus-g4 6fd5aef8: (a) the engineer's own stated forgery recipe is REFUSED as written; (b) completed with a merge back it exits 0; (c) with no forged branch at all - a docs-only retirement signed 'frank', committed by the engineer on his own branch - it exits 0 as soon as the reviewer worktree is cut at his tip. cc/frank-opus-c6, cc/sage-opus-c6 and cc/zach-opus-g4 are all at 6fd5aef8 in the live repository right now. Separately: route 4 is re-opened (a committed probe deletion is concealed by ONE uncommitted, wrongly-signed TSV line, exit 0) and route 1 is re-opened (a not-a-probe marker in the SAME COMMIT as an engine change is accepted, exit 0).

## Proceeding meanwhile

NOT CERTIFIED is committed at 86062927 on cc/frank-opus-c6 with every reproduction and exit code. Items 1, 3 and 4 hold; item 2 does not.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260912T160559Z-9474bca5`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260912T160559Z-9474bca5 --disposition "<what you decided or did>"
