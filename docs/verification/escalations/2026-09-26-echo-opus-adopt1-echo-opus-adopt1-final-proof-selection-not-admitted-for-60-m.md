# Escalation: echo-opus-adopt1 final proof selection not admitted for 60+ min: host CPU 100 percent, about 65 percent system time

- id: `esc-20260926T135004Z-094d0d29`
- raised: 2026-09-26T13:50:04Z
- from: echo-opus-adopt1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-adopt1` (branch `cc/echo-opus-adopt1`)
- head: `62272e4f698c65c1f21ea0ad7ea19aa4044518a3`
- state: **proceeding**
- for: lead

## The question

Keep waiting for admission, or accept the per-unit receipts already run (listed in my report) and have the final re-run happen at your land check?

## What was already tried

proof-run.py --working (private CARGO_TARGET_DIR) at 12:52Z: belief_trigger_tests passed, then between_turn_thread_tests waited its full 1800 s and was not admitted; the run cancelled the rest. reserve.py --wait 570 twice since (13:30-13:49Z): 100 percent busy every sample, user about 35 percent, system about 65 percent. ps shows no single hot process; the churn is short-lived bash, sleep, lsof and Python from engine mutant sandboxes and other agents' polling loops. Nothing of mine is running: no guest, no richos-tauri on this Mac.

## Proceeding meanwhile

All work is committed on cc/echo-opus-adopt1; retrying the selection as soon as a sample is under 80 percent.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260926T135004Z-094d0d29`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260926T135004Z-094d0d29 --disposition "<what you decided or did>"
