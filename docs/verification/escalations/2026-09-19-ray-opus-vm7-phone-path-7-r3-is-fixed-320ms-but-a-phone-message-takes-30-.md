# Escalation: Phone path .7: R3 is fixed (320ms) but a phone message takes 30-55s to REACH the Mac, and 1 in 4 never arrived

- id: `esc-20260919T221012Z-d4f357f1`
- raised: 2026-09-19T22:10:12Z
- from: ray-opus-vm7
- worktree: `/Users/alex/ab/richos-wt/ray-opus-vm7` (branch `cc/ray-opus-vm7`)
- head: `5f3a1a1e6e451fb369377fb77b20c9085488c969`
- state: **work-complete**
- for: lead

## The question

Can a guest with claude signed in be provided for one re-run of step 4? That single run decides whether the 30-55s delivery is a no-engine artifact or the phone path's headline defect.

## What was already tried

Walked the whole path in the test VM on nightly .7. Split the trip in two using the Mac's own intake log: send->intake 30.67s / 48.79s / 54.47s, intake->repaint 320ms. One of four sends was refused outright ('Your Mac did not accept it'). Every claimed fix (R3, D1, D2, sheet controls, reopen focus, one path) verified FIXED on screen. Phone-side backoff ceiling MAX_RETRY_MS=30000 (link.js:66) matches the spread.

## Proceeding meanwhile

Audit committed with frames, OCR gate clean over 15 frames, VM stopped and node signed out.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T221012Z-d4f357f1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T221012Z-d4f357f1 --disposition "<what you decided or did>"
