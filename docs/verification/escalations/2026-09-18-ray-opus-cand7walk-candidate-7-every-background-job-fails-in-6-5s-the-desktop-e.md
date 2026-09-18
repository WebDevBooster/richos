# Escalation: Candidate .7: every background job fails in 6.5s — 'The desktop engine plugin did not load'

- id: `esc-20260918T081523Z-4abcf345`
- raised: 2026-09-18T08:15:23Z
- from: ray-opus-cand7walk
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand7walk` (branch `cc/ray-opus-cand7walk`)
- head: `9da3c7d59e8defcbf0844a7d94619adb57ede533`
- state: **proceeding**
- for: lead

## The question

Is the work-lease engine plugin failing to load a product defect in 9da3c7d5, and does .7 hold until it is fixed?

## What was already tried

Connected the QA fixture repository through Settings, gave Rich the notes.txt job in his own words. Assignment 581ed860 registered at 08:13:04.452Z and went state=failed at 08:13:10.997Z with detail 'cognition protocol: The desktop engine plugin did not load'. notes.txt is still 'hello'; nothing landed. The conversation lease's engine profile (00baa8be) and the work lease's (200b6480) carry byte-identical .claude-plugin/plugin.json, so the conversation lease loads the same plugin the work lease cannot.

## Proceeding meanwhile

Walking everything that does not depend on a job completing: front-desk responsiveness, window close/reopen, quit-with-work-running, relaunch recovery, and the CEO's barge-in sentence.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T081523Z-4abcf345`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T081523Z-4abcf345 --disposition "<what you decided or did>"
