# Escalation: Candidate .15 cannot answer any typed message: the engine refresh is never offered and the turn is refused before it starts

- id: `esc-20260919T152225Z-2e44d112`
- raised: 2026-09-19T15:22:26Z
- from: ray-opus-cand15
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand15` (branch `cc/ray-opus-cand15`)
- head: `dcebed09b4d09ba139be8b03bd26e12e26058350`
- state: **proceeding**
- for: lead

## The question

Does the .15 walk continue against a scratch HOME whose engine cannot start the front desk, or do you re-point/refresh the engine and relaunch so questions 3, 4 and 5's live messaging can actually be walked?

## What was already tried

Entered via the door on the home screen; typed the question-4 job into the composer and sent it. The turn failed with no answer at all. app.log: 'turn interrupted [transient]: cognition io: .../Application Support/RichOS/engine: the engine there carries the right version and different contents - installed from 3313945b26b7, and this build pins adece4c069e4' twice, then 'text turn refused before it started (the spine refused the prompt)'. The screen shows 'Stopped' and 'I lost my connection to the part of me that thinks, partway through... asking again is worth a try'. The brief's premise that the engine refresh offer is on screen is FALSE - no setup sheet appeared at entry or since (verified live across four captures, 16:08-16:4x).

## Proceeding meanwhile

Questions 2 and 7's geometry are measured and pass (home 18/18, thread header 6/15). Continuing with question 1's phone-path screens, question 6's text size, and the phone pairing, all of which are UI/Rust-side and do not need the model.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T152225Z-2e44d112`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T152225Z-2e44d112 --disposition "<what you decided or did>"
