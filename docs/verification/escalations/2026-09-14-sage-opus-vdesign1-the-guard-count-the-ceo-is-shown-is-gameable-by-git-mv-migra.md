# Escalation: The guard count the CEO is shown is gameable by git mv; migration step 3 is gated on replacing it

- id: `esc-20260914T222845Z-3db2a4ce`
- raised: 2026-09-14T22:28:45Z
- from: sage-opus-vdesign1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-vdesign1` (branch `cc/sage-opus-vdesign1`)
- head: `671b544c7ddcddf81c351718b50f66a5605c12aa`
- state: **work-complete**
- for: lead

## The question

Do you replace the reported metric with blocking-control count + positions-per-rule before anyone executes migration step 3, or do we report the honest target 87 instead of 58?

## What was already tried

Measured it: 104 non-test hook scripts includes 29 mutation harnesses, none of which is registered as a hook. Moving them to scripts/mutations/ would drop the headline 28% tonight and change nothing. I refused to do that as my first step and deleted a real guard instead (104 -> 103, verified: probe rc 0, contract-integrity 180/180, census CONTROL 37 -> 36).

## Proceeding meanwhile

Design committed at af995c3c with the migration ordered so steps 1 and 2 (derive the typed inventories, settle the dead second registration surface) pay the largest fraction first, even though step 1 moves the count by zero. Step 3 is explicitly gated in the document.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T222845Z-3db2a4ce`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T222845Z-3db2a4ce --disposition "<what you decided or did>"
