# Escalation: runner-reliability flake: the brief's failure point is wrong; the failure is 'child did not start', not held()!=1

- id: `esc-20260926T052217Z-a0a119e4`
- raised: 2026-09-26T05:22:17Z
- from: zach-opus-flaky1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-flaky1` (branch `cc/zach-opus-flaky1`)
- head: `490d47070efad00e9d6be972e12eb036a6526202`
- state: **proceeding**
- for: lead

## The question

None needed unless you object: both nightly logs (20260925T233119Z-f45b74e4 line ~4130, 20260926T051037Z-90d80e01 line 2898) fail at line 108 'child = self.wait_file(record)' with 'child did not start' after 10 s, not at the held()==1 assertion on line 109. Working hypothesis: the test is the only one in the file that does not give its wrapper a private RICHOS_MACHINE_WORKERS, so under a nightly it inherits the real 8-token machine budget and waits for a machine token while the nightly holds them all.

## What was already tried

Read both logs' tracebacks and compared every other test's env handling in runner-reliability.test.py

## Proceeding meanwhile

Reproducing with a private full machine budget, then fixing the test's isolation and adding a machine-lease assertion plus mutation check

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260926T052217Z-a0a119e4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260926T052217Z-a0a119e4 --disposition "<what you decided or did>"
