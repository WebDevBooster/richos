# Escalation: Candidate .16: the engine offer reaches the screen but does not hold focus, and one Escape still dismisses it

- id: `esc-20260919T171553Z-e42d1166`
- raised: 2026-09-19T17:15:53Z
- from: ray-opus-cand16
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand16` (branch `cc/ray-opus-cand16`)
- head: `4f2d57c9f9519409427b86c7502b9a7588216bf1`
- state: **proceeding**
- for: lead

## The question

Does question 1 pass when the offer is visible at entry but focus is in the composer and a single Escape still removes it, given the offer now returns on the next typed send and no declination is persisted?

## What was already tried

Entry state of pid 49243 captured untouched; AXFocusedUIElement read as 'text area Message to Rich' with the sheet on screen; one Escape at the home screen removed the sheet from the AX tree with no change to config.json, no new state file and no app.log line; a later typed send brought the offer back and focus was then on 'Set it up'

## Proceeding meanwhile

Questions 2, 3, 5 and 6 measured; the refresh itself succeeded and the engine now records the pinned adece4c0

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T171553Z-e42d1166`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T171553Z-e42d1166 --disposition "<what you decided or did>"
