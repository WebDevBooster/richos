# Escalation: The engine's only delivery gate rests on a host behavior nobody has measured: TaskCompleted exit 2

- id: `esc-20260914T171758Z-b933947d`
- raised: 2026-09-14T17:17:58Z
- from: sage-opus-c1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-c1` (branch `cc/sage-opus-c1`)
- head: `0c45562df68572951d560ce09a48d3f6bb3c1e5a`
- state: **work-complete**
- for: lead

## The question

Should someone probe whether a TaskCompleted hook exiting 2 actually holds a native task open, before task-completed-handoff.sh keeps being treated as the gate that proves delivery?

## What was already tried

Derived it in the check census: of 36 controls, 30 sit on PreToolUse and 5 on Stop, and BOTH of those host behaviors are measured in this repository. task-completed-handoff.sh is the only control on a third event. Its authority is claimed by its own header at line 12 ('a refused proof exits 2 so the native task remains open with remediation') and by nothing else: grep -rn 'remains open|task stays open' engine/scripts/ returns that header alone, and no probe anywhere measures the event. If the assumption is wrong the delivery gate is an instrument and its refusals have been silently discarded.

## Proceeding meanwhile

The census, the record and the one live defect it found are committed on cc/sage-opus-c1; this does not block any of it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T171758Z-b933947d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T171758Z-b933947d --disposition "<what you decided or did>"
