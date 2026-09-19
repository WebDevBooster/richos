# Escalation: Candidate .13: first reply is 8.97 s — between the two numbers the CEO named, and only he can set the line

- id: `esc-20260919T100554Z-8f051691`
- raised: 2026-09-19T10:05:54Z
- from: ray-opus-cand13
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand13` (branch `cc/ray-opus-cand13`)
- head: `6acfaf8052bee630668ad731f8e1fda4311765f5`
- state: **work-complete**
- for: ceo

## The question

Is roughly 9 seconds to 'On it!' within 'a few seconds'? If yes, candidate .13 has no blocker left on the Mac; if no, the remaining time is model time and needs a different fix from the one that just landed.

## What was already tried

Walked candidate .13 end to end on the real window and on the CEO's Android. Timed send to first words with a 0.37 s filmed loop: absent at 8.511 s, present at 8.967 s, header reading 'Working for 8s' at that instant, so ~1 s is pre-turn against .12's ~6 s. The prime wait is gone and proved gone by the boot log. Everything else this build was asked to fix is fixed and measured: his three screenshot numbers at 0 px / 15 px / 46 px in both themes at both window sizes, CEO 62 proved from pixels, CEO 63 proved both directions, and every Urban gap I could reach.

## Proceeding meanwhile

Audit committed with the measurement and my plain reading that 9 s is not 'a few seconds'. Two lower defects are ranked in it and do not depend on this answer: the phone does not open a thread at its newest message (medium), and a text-size change leaves the composer field 2 px short until the next keystroke (low).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T100554Z-8f051691`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T100554Z-8f051691 --disposition "<what you decided or did>"
