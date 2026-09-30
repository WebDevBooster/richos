# Escalation: zach-sonnet-engine5c: CPU admission has refused every proof run for 25 minutes (host at 100%, system 66%)

- id: `esc-20260930T174218Z-567bab0b`
- raised: 2026-09-30T17:42:18Z
- from: zach-sonnet-engine5c
- worktree: `/Users/alex/ab/richos-wt/zach-sonnet-engine5c` (branch `cc/zach-sonnet-engine5c`)
- head: `f10a5fb02e8a122e637050f49fa081a6195478a0`
- state: **proceeding**
- for: lead

## The question

May my small proof scripts (a few seconds each, single process: two shell tests and one python unittest) run directly without reserve.py while the host stays above 80% CPU? Or does someone clear the system-CPU fault?

## What was already tried

reserve.py --wait 300 and --wait 580 both ended refused: total CPU 100%, user 33%, system 66%, idle 0%, memory normal, 20 samples over 581 s. Earlier single sample 89%.

## Proceeding meanwhile

All six fixes are written (P5-69 to P5-74 all still open on current main by source reading). Continuing with edits and commits; red/green proof output is pending on admission.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260930T174218Z-567bab0b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260930T174218Z-567bab0b --disposition "<what you decided or did>"
