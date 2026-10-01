# Escalation: iPhone D3: cause found and fixed (e84a8e8d3); the on-phone check is ready and needs the CEO's one approval at the test iPhone

- id: `esc-20261001T140745Z-e3e24f20`
- raised: 2026-10-01T14:07:46Z
- from: isaac-opus-d3d
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-d3d` (branch `cc/isaac-opus-d3d`)
- head: `e84a8e8d3731cb66ab906bea6d5fad80322f5b48`
- state: **proceeding**
- for: lead

## The question

Tell me when the CEO is at the test iPhone. The fix check is one phone session (about 3 minutes, three send-then-Home tries) that will ask him once for Touch ID or the passcode to allow UI automation. The fixed signed build is already published (store key 0ca027910ec6b3f72a4c03c4), the isolated lab is running and the phone is still paired to it, so the run starts within seconds of your word.

## What was already tried

Reproduced on the phone at 13:53-13:56Z: 3 of 3 in-flight tries stayed on the phone while hidden. The phone's own send log shows the cause: the request in flight at Home came back a transient fault about 1.4 s into the 5 s bound after Home, then the batch ENDED with 1 still to send and gave the background time back, so iOS had given time and the app returned it (nothing retries a waiting message off screen: the tick and connected both need the stream, which is closed when hidden). Fix: while hidden inside a started bound, a transient failure goes again under the same id after the outbox's own pause, within the existing 5 s bound and 3-request cap; exactly once holds (the Mac keeps one copy per id). New test SendThenHomeTests.aFaultWhileHiddenGoesAgainInsideTheBound: red before, green after; 28 tests in the 6 neighboring suites green.

## Proceeding meanwhile

Keeping the lab running and the phone paired to it; finishing the report. No phone session starts until you say the CEO is there.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T140745Z-e3e24f20`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T140745Z-e3e24f20 --disposition "<what you decided or did>"
