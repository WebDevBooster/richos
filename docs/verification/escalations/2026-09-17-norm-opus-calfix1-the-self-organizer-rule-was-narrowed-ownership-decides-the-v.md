# Escalation: The self-organizer rule was narrowed: ownership decides, the vendor's self flag does not

- id: `esc-20260917T103113Z-5059d7a4`
- raised: 2026-09-17T10:31:13Z
- from: norm-opus-calfix1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-calfix1` (branch `cc/norm-opus-calfix1`)
- head: `31a4b402d492806cba1394b05e47c7e5b633cd90`
- state: **work-complete**
- for: lead

## The question

Confirm the narrowing: is 'the vendor flags organizer.self' dropped as an independent clause, leaving ownership from calendarList as the whole test?

## What was already tried

Implemented and shipped the ownership clause (selfCalendars in ceoIdentity, 'owned' per calendar from the adapter's existing accessRole, folded into the identity in ingestOnce). Verified the reported case is fixed: board-prep-shared now predicts and observes PROMOTED. Added a control that bites - a subscribed read-only calendar's meeting stays external and held; removing the owned filter fails the run.

## Proceeding meanwhile

Both parts are committed on cc/norm-opus-calfix1. Part 1 (the events.import 400) is unaffected by this question.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T103113Z-5059d7a4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T103113Z-5059d7a4 --disposition "<what you decided or did>"
