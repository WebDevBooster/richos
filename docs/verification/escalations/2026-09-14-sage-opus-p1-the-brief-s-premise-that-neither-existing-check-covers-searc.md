# Escalation: The brief's premise that neither existing check covers search-blindness is false, and the real instances cited no search at all

- id: `esc-20260914T131758Z-88b59b32`
- raised: 2026-09-14T13:17:58Z
- from: sage-opus-p1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-p1` (branch `cc/sage-opus-p1`)
- head: `015aef5710c4799a89d27a5e06a10669950bfb73`
- state: **work-complete**
- for: lead

## The question

Nothing needs deciding to finish this; the thing to know is that the durable defense here is the engineer re-deriving a marked claim, not a check — does anything follow from that for how briefs are written?

## What was already tried

Re-derived all three instances against the code. Two of three are in the 30-brief corpus and NEITHER cited a search: tom7-brief.md line 11 and zach13-brief.md relayed conclusions, both marked, both caught and escalated by the engineer. Reconstructed with their commands, the existing checks already row two of the three. The positive-control candidate catches zero of three. Built check 5 anyway for the category it does cover: 4 rows over 30 briefs, 3 real.

## Proceeding meanwhile

Work complete and committed: 76d7adb5 (check 5 + 15 test cases, 47/47) and 015aef57 (the record answering the CEO).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T131758Z-88b59b32`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T131758Z-88b59b32 --disposition "<what you decided or did>"
