# Escalation: A screen-waiting assignment can make the work chip vanish, and the fix is in ui/main.js which was not mine this round

- id: `esc-20260918T114550Z-64ae379a`
- raised: 2026-09-18T11:45:50Z
- from: echo-opus-screenwait1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-screenwait1` (branch `cc/echo-opus-screenwait1`)
- head: `748f4687833562f3c078919cfca925419a0e89b3`
- state: **work-complete**
- for: lead

## The question

Who takes ui/main.js:2918 after echo-opus-ui1 lands, and does the new chip part read 'N waiting for the screen'? Adding waiting-for-screen to the existing running list is the wrong fix and would call a parked job running.

## What was already tried

Read the site rather than assumed it. ui/main.js:2918 builds openWork from the typed list registered/preparing/running. A waiting-for-screen assignment is in none of them, so if it is his ONLY open work and savedWork, awaiting and unknown are all empty then parts is empty and drillChipEl.hidden = true - the chip disappears and the pane the assignments live in cannot be reached at all. The comment four lines above that line warns about exactly this - no chip, no pane, no approve control. I fixed the half that was mine, ui/work-summary.js, where the same new state word would have rendered as 'Its state could not be read.'

## Proceeding meanwhile

Work is complete and committed on cc/echo-opus-screenwait1 at 748f4687. The screen-wait slice is green and does not depend on this; the chip only misreports when a screen wait is the sole open assignment. Also outstanding and recorded in docs/verification/screen-wait-2026-09-18: the end-to-end walk on a really locked screen was never done, because the CEO was at the desk all day and sysadminctl reports a 300 second screenLock delay so pmset would not have produced a lock anyway.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T114550Z-64ae379a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T114550Z-64ae379a --disposition "<what you decided or did>"
