# Escalation: Candidate .12: every .11 defect fixed except the one threshold only the CEO can set — first words at 14.24 s

- id: `esc-20260919T034134Z-3f1f4ded`
- raised: 2026-09-19T03:41:34Z
- from: ray-opus-cand12
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand12` (branch `cc/ray-opus-cand12`)
- head: `a08cc7888e9bb77ca93011515c3f7b0cdb7b59dd`
- state: **work-complete**
- for: ceo

## The question

Is 14.24 s to the first words on screen acceptable, or must 'On it!' be said by the receipt before the model runs? His words name 'a few seconds' and 35 s, and this sits between them.

## What was already tried

Full re-walk of all 18 rows of the .11 table on 1.2.0-nightly.20260919.1 (build f74d25e6 = a08cc788 + version bump only). 14 FIXED, 2 NOT REACHED live (code cited as supporting evidence only), 2 partly fixed. Both of .11's mechanical causes for row 6 are gone: the message never leaves the screen (visible at t=0.08 s) and the primed desk was consumed at 0 ms per the app log. The residue is ~6 s pre-turn overhead plus ~8 s model time. The log shows the receipt path already exists and deduplicates the model's own 'On it!'.

## Proceeding meanwhile

Audit committed with 33 frames, 0 privacy hits. Phone unpaired, app quit, pid 2021 gone, no residue. Two new lower-severity defects recorded below the table (one control with two names across the two settings panels; the expired-code card keeps an instruction whose subject is gone).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T034134Z-3f1f4ded`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T034134Z-3f1f4ded --disposition "<what you decided or did>"
