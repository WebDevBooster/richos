# Escalation: The worker now works and the review passes; the land dies on the host's continuation turn being answered by a turn the platform injected

- id: `esc-20260918T211207Z-52acb812`
- raised: 2026-09-18T21:12:07Z
- from: echo-opus-worktree1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-worktree1` (branch `cc/echo-opus-worktree1`)
- head: `5138798ec70889274c3cb5749ccefd5c999d6520`
- state: **work-complete**
- for: lead

## The question

Who takes the turn-collision in work_host's wait loop, and may a third real-provider run be spent to prove the land end to end?

## What was already tried

Two real work_lease_roundtrip runs (the brief's budget). RED at ff821816 reproduced exactly: t+45.294s 'A helper is doing the work' then t+150.987s 'The work ran and nothing was landed'. Cause was NOT a missing worktree: the target worktree was created at 20:44:45 and the worker's every tool call was refused by the app's own turn gate ('This app turn is stopped or is supplying context'), quoted from the worker's own last words in that run's callbacks.jsonl row 21; producing nothing, it was auto-disposed as landed (point 7) and its worktree deleted at 20:45:46, which is why target-worktrees/<partition>/ is empty. Fixed at 5138798e (ecs::ToolScope.background_work_allowed; a turn end keeps it, a stop/assignment-end/crash-recovery revokes it; app-engine-hook admits an agent_id-bearing call to the WORKER's gates, which all still run). GREEN run: the worker edited notes.txt, committed 8ddc3f4 on cc/worker-sonnet-11aaf7fa02a8, handed back successfully; a reviewer was prepared, dispatched, checked the commit byte-for-byte and PASSED it. All of that was impossible before. The land did not happen: the host's second continuation turn returned 1.847s after the reviewer's SubagentStop with zero tool calls (measured: assignment updated_at_ms 1789765580151 minus reviewer end 1789765578.304). NativeClient::prompt has no correlation between the message it sends and the result frame it returns on (native.rs:2395-2425), and the platform injects its own turns into the lease (callbacks rows 52, 55, 92 are a subagent hand-back and a task-notification, not host prompts), so the host's continuation was answered by the tail of an injected turn already in flight.

## Proceeding meanwhile

Landing the proven fix, its two probed-both-ways tests and the measured record on cc/echo-opus-worktree1; not guessing at a fix for the collision with no budget to prove it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T211207Z-52acb812`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T211207Z-52acb812 --disposition "<what you decided or did>"
