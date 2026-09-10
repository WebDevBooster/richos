# Escalation: The by-reference probe route is RED on pristine main: BR2 does not know the two CI-surface hooks

- id: `esc-20260910T082120Z-c5634086`
- raised: 2026-09-10T08:21:20Z
- from: zach-opus-q1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-q1` (branch `zach-opus-q1`)
- head: `d5d52f2c90a59451d54fc13c5737c0aaa542d63e`
- state: **work-complete**
- for: lead

## The question

Who adds guard-ci-red-lands.sh and session-start-ci-surface.sh to BR_EXPECTED in contract-integrity-probe.sh — the agent that registered them in hooks/hooks.json, or a follow-up?

## What was already tried

Reproduced on the pristine checkout with none of my changes in the tree, by running engine/scripts/hooks/by-reference.test.sh there. Four cases fail, identical to the four on my branch: 0a, 0b, 6g and 10f. All four trace to one BR2 line naming guard-ci-red-lands.sh and session-start-ci-surface.sh as registered in the plugin hook table but absent from BR_EXPECTED, with the remedy 'Add them to BR_EXPECTED'. They were registered by 1e874445 at 08:10 today. The probe run with a femcboost working directory exits 2 for the same reason. I did not touch it: those scripts belong to another agent right now, and a BR_EXPECTED entry declares their event and order, so a wrong or stale entry would be a false attestation.

## Proceeding meanwhile

My own task is complete on branch zach-opus-q1: the seated probe exits 0 with 27 layers green, Q among them.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T082120Z-c5634086`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T082120Z-c5634086 --disposition "<what you decided or did>"
