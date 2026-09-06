# Escalation: The survey inverts the brief: 19 of 25 PreToolUse guards fail open, 17 silently; the Stop hooks are the safer half

- id: `esc-20260905T113814Z-9b07961c`
- raised: 2026-09-05T11:38:14Z
- from: zach-opus-fc1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-fc1` (branch `zach-opus-fc1`)
- head: `48f50a5f33d556daac480edff9d26457e3d13b61`
- state: **work-complete**
- for: lead

## The question

Given that the platform already cancels a stalled hook and lets the tool call proceed, is the change you want the bounded read at all, or the fail-closed template at the four or five gates where a silent pass actually costs something?

## What was already tried

Drove all 40 hooks with empty, truncated and non-JSON payloads plus per-hook violation controls and bash -x traces; two entity roots; state snapshotted and restored.

## Proceeding meanwhile

Brief committed at 48f50a5 with the per-hook table, the harness and the raw results; no guard was modified.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T113814Z-9b07961c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T113814Z-9b07961c --disposition "<what you decided or did>"
