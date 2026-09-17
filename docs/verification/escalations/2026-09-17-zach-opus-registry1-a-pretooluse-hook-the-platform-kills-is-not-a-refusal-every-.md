# Escalation: A PreToolUse hook the platform KILLS is not a refusal: every blocking guard in this engine can be bypassed by making it slow

- id: `esc-20260917T115520Z-49de5cd0`
- raised: 2026-09-17T11:55:20Z
- from: zach-opus-registry1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-registry1` (branch `cc/zach-opus-registry1`)
- head: `0703212a231441a1d3d39002a6634a57d31f02ec`
- state: **work-complete**
- for: lead

## The question

Should the other seven PreToolUse[Agent] guards' budgets be audited against their own worst case the way guard-worktree-isolation.sh now is, or is the repair-after-the-fact pattern the answer for all of them?

## What was already tried

Measured on this machine: guard-worktree-isolation.sh ran 10.027s against a 10s budget on 2026-09-17 and the orchestrator transcript records it as hook_cancelled/timedOut:true for tool_use_id toolu_01C3dCBDwFksv5tBHramMDch; the Agent tool then reported 'Async agent launched successfully' two seconds later. So the guard's clauses 1-6 (isolation shape, name rules, cwd-only refusal) did not refuse that spawn either - nothing in the file was reached. Three PreToolUse:Agent timeouts exist across this project's transcripts. Its budget is now 60s and the missed registration is repaired automatically, which covers this guard only.

## Proceeding meanwhile

Nothing. The assigned work is committed on cc/zach-opus-registry1 and sage-opus-nightly1's workspace is retired through the fixed path.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T115520Z-49de5cd0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T115520Z-49de5cd0 --disposition "<what you decided or did>"
