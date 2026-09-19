# Escalation: Making the Settings control unreachable during the first-run offer contradicts §15's 'Bust a bug from EVERY screen'

- id: `esc-20260919T213047Z-ffae17ba`
- raised: 2026-09-19T21:30:47Z
- from: echo-opus-offer3
- worktree: `/Users/alex/ab/richos-wt/echo-opus-offer3` (branch `cc/echo-opus-offer3`)
- head: `5c5a2a8b5e0e3550547677f08180e96bdd52e2a5`
- state: **work-complete**
- for: ceo

## The question

While a first-run question is on screen, should the top-right Settings control stay unreachable (what I built, and what the window already did in practice), or must Bust a bug remain reachable through the question, which needs a way in that a modal does not currently have?

## What was already tried

Measured on the real binary before the fix: the control took focus AND opened the menu over the unanswered question, so §15's floor was already only half kept. I made the refusal honest — everything outside the question is inert, so the control cannot take focus at all — and setup.js case 20 holds it. style.css's own note argues z-index 300 exists so the button is reachable 'including the one a first-run user is most likely to be stuck on', which is exactly this screen.

## Proceeding meanwhile

All four brief items are landed on cc/echo-opus-offer3 and proven in the VM; nothing else waits on this answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T213047Z-ffae17ba`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T213047Z-ffae17ba --disposition "<what you decided or did>"
