# Escalation: guard-worktree-removal.test.sh and inflight-ack-durability.test.sh journal and archive into the operator's real retirement state on every run

- id: `esc-20260906T023729Z-14672a89`
- raised: 2026-09-06T02:37:29Z
- from: zach-fable-rm4
- worktree: `/Users/alex/ab/richos-wt/zach-fable-rm4` (branch `zach-fable-rm4`)
- head: `f6c1d4039b956b058c8e2bcc339609c04176c7c7`
- state: **work-complete**
- for: lead

## The question

May run_case/helper_case in engine/scripts/hooks/guard-worktree-removal.test.sh and the sandbox setup in engine/scripts/hooks/inflight-ack-durability.test.sh export RICHOS_WORKSPACE_RETIRE_DIR=<sandbox>/retire-state beside the RICHOS_WORKTREE_LEDGER they already pin? Both are zach-opus-mr2's files and I have not touched them; the reaper's suite got the same pin on my branch.

## What was already tried

Measured, not inferred. Before my work the real journal held 1,304 records and 650 lock files, all naming sandbox paths and none a real retirement (the reaper's suite, now pinned on zach-fable-rm4). Running the two hook suites once each against my branch added 65 records (21 remove intents, 21 quarantined completions, 23 notes) and 21 archives under ~/.claude/state/workspace-retirement/preserved/, every one a sandbox fixture, because the remover now preserves every tree it retires. I left them in place: not mine to erase. The same two suites also still carry the cases esc-20260906T002609Z-c33e25f5 names (H4 expects exit 0 for an owner nobody registered; 3a's fixture registers no owner) and fail on them for the designed reason, unchanged by this round.

## Proceeding meanwhile

Nothing pending on my side; the branch is complete. This is a record.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T023729Z-14672a89`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T023729Z-14672a89 --disposition "<what you decided or did>"
