# Escalation: Check 5 was not red on main — it was green over a photograph of the home screen, and the 50ms window is 270ms

- id: `esc-20260905T120306Z-6339f7de`
- raised: 2026-09-05T12:03:06Z
- from: echo-opus-sh1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-sh1` (branch `echo-opus-sh1`)
- head: `ba5fcfdd6c90ca45693d6ad0a7573ce18ca5da89`
- state: **work-complete**
- for: lead

## The question

Should check 18's matShot guard, which uses the same DOM-presence test I found insufficient, be fixed in a follow-up? It has 3.8s of margin today so it is not failing, but it is the same defect shape one constant change away from firing.

## What was already tried

Re-derived the window from app/ui/splash.js and measured it in WebKit: shutter opens at holdMs+FLARE_MS(950), node removed at holdMs+CEILING_GRACE_MS(1000)+FADE_MS(180)+40, so the window is 270ms not 50ms - measured 271ms at seconds:3, 265ms at seconds:5, removal instant 4221ms vs 4220 derived. Ran the suite at 787b101 to confirm red, and at ba5fcfd to confirm green at 0ms, 400ms and 3000ms of injected shutter lag.

## Proceeding meanwhile

Fix landed as briefed: option 1, NO_CEILING opt-in, two call sites, no product byte touched. Full suite green, 444 checks over 23 suites.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T120306Z-6339f7de`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T120306Z-6339f7de --disposition "<what you decided or did>"
