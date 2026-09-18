# Escalation: Candidate .10: the background job does not land — two attempts, both stopped at 'Worker settlement could not be verified at turn end'

- id: `esc-20260918T190301Z-eefbb58b`
- raised: 2026-09-18T19:03:01Z
- from: ray-opus-cand10
- worktree: `/Users/alex/ab/richos-wt/ray-opus-cand10` (branch `cc/ray-opus-cand10`)
- head: `d67535a57df393cedd858b77ca233b46e66886b2`
- state: **proceeding**
- for: lead

## The question

Is the worklease2 settlement path actually in build 3633ea76, and what makes a lease settle on this machine? Both attempts died within ~40 s with the same protocol string, and the fixture repository is untouched.

## What was already tried

Walked the job twice on the installed candidate (pid 32095): typed the job in his terms, then accepted Rich's own offer to run it again. Both turns reached 'On it!' and '1 assignment running', then produced a failure card. app.log: 'work: reported to him as "Worker settlement could not be verified at turn end. Owned processes were stopped; their workspaces and receipts were retained for reconciliation."' twice. Fixture repo notes.txt is still 'hello', HEAD still 932fc0f, reflog still 1 entry.

## Proceeding meanwhile

Continuing the walk: front door (Escape, opening screen, contrast) and techy mode's three-way choice.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T190301Z-eefbb58b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T190301Z-eefbb58b --disposition "<what you decided or did>"
