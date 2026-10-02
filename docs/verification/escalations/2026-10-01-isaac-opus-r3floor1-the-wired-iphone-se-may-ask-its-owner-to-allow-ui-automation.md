# Escalation: The wired iPhone SE may ask its owner to allow UI automation for the R3/R2-floor/refused-reason check

- id: `esc-20261001T224807Z-8528c55e`
- raised: 2026-10-01T22:48:07Z
- from: isaac-opus-r3floor1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-r3floor1` (branch `cc/isaac-opus-r3floor1`)
- head: `ae9b1f083115fd11328c9fb55c0e900c1ae91e55`
- state: **proceeding**
- for: lead
- needs: **ceo-hands** (the answer needs the CEO at a device)

## The question

If the iPhone SE shows an 'Allow UI automation' (or Trust) prompt in the next half hour, can the CEO approve it at the phone?

## What was already tried

phone-ios.py approval forecasts approvalExpected=true only because it cannot read the passcode state from this checkout (no session on record here). Re-walk 4 read passcodeConfigured=false at 19:41Z and its sessions enabled automation in 0.7-1.5 s with no prompt, so a prompt is unlikely but not ruled out.

## Proceeding meanwhile

Committing the three fixes and starting the device session with --approval-announced; if the phone prompts and nobody approves, the session times out and I report that the on-device check is outstanding.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T224807Z-8528c55e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T224807Z-8528c55e --disposition "<what you decided or did>"
