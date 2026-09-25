# Escalation: Real pause already exists in the engine; 2026-09-18 broke because the hold messages lacked the pause-until: line

- id: `esc-20260925T004049Z-6b94d42d`
- raised: 2026-09-25T00:40:49Z
- from: zach-opus-quota1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-quota1` (branch `cc/zach-opus-quota1`)
- head: `bd05d1b117bf8595c23e60fb4bb7abe6b476a86c`
- state: **proceeding**
- for: lead

## The question

None blocking: confirm you want the quota watcher to print the pause message WITH a 'pause-until:' line (the registry's existing pause trigger) rather than a new pause command

## What was already tried

Read mega-lander/workspaces.py point 11 (pause/resume, finished_state), guard-resume-isolation.sh case (0), tests T11/C11/G07/S3.2; registry events.jsonl has 0 pause events ever; 5645c662 transcript 15:04Z shows the three PAUSE messages had no pause-until: line, so SubagentStop recorded them finished and the 15:09Z wakes were refused

## Proceeding meanwhile

Building quota-watch.sh so its printed pause message carries 'pause-until: the five-hour quota reset at HH:MMZ', plus an end-to-end test that the printed message keeps the agent paused through SubagentStop and its wake is allowed, and that the 09-18 message shape is still refused

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T004049Z-6b94d42d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T004049Z-6b94d42d --disposition "<what you decided or did>"
