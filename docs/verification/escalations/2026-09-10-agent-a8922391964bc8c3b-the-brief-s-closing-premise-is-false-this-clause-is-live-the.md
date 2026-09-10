# Escalation: The brief's closing premise is false: this clause is live the moment the branch lands, not next session

- id: `esc-20260910T063558Z-d04e35b3`
- raised: 2026-09-10T06:35:58Z
- from: agent-a8922391964bc8c3b
- worktree: `/Users/alex/ab/femcboost/.claude/worktrees/agent-a8922391964bc8c3b` (branch `worktree-agent-a8922391964bc8c3b`)
- head: `0daa9529fe5969cd0c2e35bd1dcb48874f9237ce`
- state: **work-complete**
- for: lead

## The question

Tell the CEO he is protected from the next spawn after the merge, not from his next session. Do you want that wording checked against anything before it reaches him?

## What was already tried

hooks.json registers the command as bash PLUGIN_ROOT/scripts/hooks/verify-agent-prompt.sh, so the body is read at every invocation; what snapshots at session start is WHICH hooks are registered, not the body of one already registered. femcboost commit 34d23cf6d records the same thing observed live.

## Proceeding meanwhile

Work complete and committed on zach-opus-gate1: suite 77/77, 17 mutants load-bearing, probe byte-identical to its green baseline.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T063558Z-d04e35b3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T063558Z-d04e35b3 --disposition "<what you decided or did>"
