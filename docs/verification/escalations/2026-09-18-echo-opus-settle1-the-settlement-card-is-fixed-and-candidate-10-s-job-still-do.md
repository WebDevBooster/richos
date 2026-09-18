# Escalation: The settlement card is fixed and candidate .10's job still does not land: the worker gets no target worktree

- id: `esc-20260918T203249Z-fee447b0`
- raised: 2026-09-18T20:32:49Z
- from: echo-opus-settle1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-settle1` (branch `cc/echo-opus-settle1`)
- head: `1c2e43a1dfa576e78d7c01638a93be03d53a3337`
- state: **work-complete**
- for: lead

## The question

Who takes the worker-workspace failure — prepare() refusing with 'I could not give this work its own separate copy of your project' and an empty target-worktrees/<partition>/ — now that the settlement kill is out of the way?

## What was already tried

Reproduced Ray's card exactly on the shipped candidate's own engine (43.085 s vs his ~39 s, same untouched fixture). Named the reading: liveness_unknown=1, agent a8be1462f8bb88ad4. Fixed: a provider-witnessed background run no longer counts as an orphan at turn end, the host now waits for SubagentStop and hands the lease a continuation turn, a failed back end is retired instead of reused, and DESKTOP.md/the brief stop naming TaskOutput (measured absent from the work lease's 30-tool init inventory). Proven end to end: turn ends, child survives, SubagentStop arrives, continuation turn runs. Tried and WITHDREW two fixes on measurement: a synchronous dispatch (refused by guard clause 7b, and workspaces.py binds the agent id at PostToolUse[Agent] so every worker tool call was refused with 'worker identity has not joined its app receipt'), and work-lease tool residency (made no difference; TaskOutput is not there at all).

## Proceeding meanwhile

Nothing — my slice is committed on cc/echo-opus-settle1 and the record is docs/verification/worker-settlement-2026-09-18.md. The remaining defect is downstream of everything I changed and needs its own slice.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T203249Z-fee447b0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T203249Z-fee447b0 --disposition "<what you decided or did>"
