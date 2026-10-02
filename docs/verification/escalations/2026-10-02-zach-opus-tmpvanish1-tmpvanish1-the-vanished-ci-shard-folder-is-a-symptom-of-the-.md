# Escalation: tmpvanish1: the vanished ci-shard folder is a symptom of the 600 s cap, not the cause of the refusals; ci-shard deletes its own folder when the gate stops it

- id: `esc-20261002T103823Z-b9e6c613`
- raised: 2026-10-02T10:38:23Z
- from: zach-opus-tmpvanish1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-tmpvanish1` (branch `cc/zach-opus-tmpvanish1`)
- head: `32ef745f2ad43d089663cc94151656f668dc81bf`
- state: **proceeding**
- for: lead

## The question

The merge gate of cc/zach-sonnet-vinputs1 will keep being refused after my fix, because by-reference.test.sh and operator-fences.test.sh are hitting the 600 s cap. Who takes their runtime? When they pass they take 402-554 s (by-reference) and 363 s (operator-fences), measured on this machine, and they go over 600 s under the gate's load. My fix stops the folder from being deleted while a unit is still running, and it keeps the unit's own log on a stop so the next timeout shows where the unit was. It does not make either unit faster.

## What was already tried

Evidence from attempt-ibez7vtf (times in the brief are BST; UTC is one hour earlier). The 02 log was created at 10:20:38Z and last written at 10:30:39Z, which is 601 s later. The 03 log was created at 10:21:13Z and last written at 10:31:14Z, also 601 s later. Both checks are recorded as timed-out with exit 124 at 601.6 s and 601.8 s, which is the gate's 600 s cap (proof-run.py stop_item sends SIGTERM, then proc_tree finish_scope sends SIGTERM to every member of the tree). Each traceback is the last write to its log, at the moment of the cap, and no ci-shard verdict line follows it. That means the ci-shard bash process had already exited when worker_tokens.py wrote its timing file. The deleter is ci-shard.sh line 561, its own trap: rm -rf LOG_DIR on EXIT. Bash runs that trap on the gate's SIGTERM while its child worker_tokens.py is still cleaning up, and the unit's own log ($LOG_DIR/1.log, which would show where the unit hung) goes with the folder. The scratch reaper did not delete it: its last run was 09:41:20Z, before the attempt started, none of the four vanished folder names appears in scratch-reaper.log or disk-watchdog.log, and ci-shard.* matches none of its declared patterns. The same signature appears in attempts pe5qjpwl (601.3 s), 9mumsc50 (601.4 s) and 9byuf3bo.

## Proceeding meanwhile

Proceeding with the brief: ci-shard allocates through lib/scratch.sh with its owner recorded, it never removes its folder while its unit is still running, it prints the unit's log tail when it is stopped, and a test shows a live ci-shard folder survives a stop. Branch cc/zach-opus-tmpvanish1.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T103823Z-b9e6c613`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T103823Z-b9e6c613 --disposition "<what you decided or did>"
