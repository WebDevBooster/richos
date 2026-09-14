# Escalation: The published correction to type U is itself a wrong number: 79 was right, the audience was not

- id: `esc-20260914T010738Z-a08adbaa`
- raised: 2026-09-14T01:07:38Z
- from: sage-opus-y1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-y1` (branch `cc/sage-opus-y1`)
- head: `25d8502b58085d0363a0d1ee614a2be703c83f3e`
- state: **proceeding**
- for: lead

## The question

Should section 10e of lifecycle-failure-record-2026-09-13.md be corrected to say the note's escalation COUNT was exactly right (79 outstanding for=lead at the write instant) and its AUDIENCE clause was the defect, rather than that the count was 79-vs-10?

## What was already tried

Replayed the append-only escalation ledger through the engine's own escalations.py outstanding() to 2026-09-13T22:58:28Z, the instant the cat-heredoc that wrote the note actually ran: 85 outstanding, 79 for=lead, 6 for=ceo, oldest 8.4 days. The record's '10 carry for=ceo' is a count of RAW LEDGER ROWS, which includes 4 since acknowledged and ignores the 51 ack rows; outstanding for the CEO is 6. Docker exhibit stands and is worse than recorded: 32.6 GB was never produced by any command (34.3 GB measured at 21:34:51Z pre-reap, 28.2 GB at 23:02:28Z).

## Proceeding meanwhile

Designed and built on the corrected premise rather than the printed one, which changed the answer: a checker that re-ran the numbers would have CONFIRMED the false sentence, so the mechanism GENERATES the facts instead. Full argument and reproduction commands in docs/verification/restart-handoff-2026-09-14.md sections 1b and 6.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T010738Z-a08adbaa`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T010738Z-a08adbaa --disposition "<what you decided or did>"
