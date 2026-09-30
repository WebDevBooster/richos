# Escalation: Hunt part 4 finding 18 needs a two-line change in mega-lander/app.py, which is outside my assigned scope

- id: `esc-20260930T180229Z-4140c9e7`
- raised: 2026-09-30T18:02:29Z
- from: zach-opus-lander3
- worktree: `/Users/alex/ab/richos-wt/zach-opus-lander3` (branch `cc/zach-opus-lander3`)
- head: `c502f43e71b8a87bbb3ae4cc7f5be3b2482af9cf`
- state: **proceeding**
- for: lead

## The question

Who changes app.py for finding 18: should zach-sonnet-lander4 (who owns app.py in this batch) add it, or may I add it as its own commit on my branch?

## What was already tried

The creator half is done on cc/zach-opus-lander3: create-teammate-worktree.sh now honors RICHOS_OPERATION_DEADLINE (epoch seconds), bounds its setup to what is left of it less a 10 s reserve, and refuses a deadline already passed (tests C46, C47). The app half is not done because the brief keeps me out of the app: app.run() (mega-lander/app.py line 184) still calls subprocess.run(..., timeout=120) without exporting RICHOS_OPERATION_DEADLINE=now+120 in the child environment (spawn.py passes its environment through to the creator unchanged), and on its own timeout it stops only the direct child, so spawn.py and the creator keep running. Until app.run exports the deadline and stops its process group on timeout, the app path of finding 18 stays open.

## Proceeding meanwhile

Proceeding with findings 11-15 and 29 in workspaces.py; nothing else depends on this answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260930T180229Z-4140c9e7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260930T180229Z-4140c9e7 --disposition "<what you decided or did>"
