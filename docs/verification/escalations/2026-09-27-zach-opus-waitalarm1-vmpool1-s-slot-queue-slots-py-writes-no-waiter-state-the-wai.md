# Escalation: vmpool1's slot queue (slots.py) writes no waiter state; the wait gate reads its waiters from ps until it records them

- id: `esc-20260927T192047Z-fb31d4e2`
- raised: 2026-09-27T19:20:47Z
- from: zach-opus-waitalarm1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-waitalarm1` (branch `cc/zach-opus-waitalarm1`)
- head: `7a07ba5d575ef7a076ece4a43839fb23aeea3648`
- state: **proceeding**
- for: lead

## The question

Should zach-opus-vmpool1's slots.py wrap its --wait loop in resource_waits.waiting(VM, reason) (engine scripts/lib/resource_waits.py, landed on cc/zach-opus-waitalarm1), so VM waiters are recorded rather than inferred from the process table?

## What was already tried

Read cc/zach-opus-vmpool1's working tree read-only: guest_slot() writes a holder record into the slot file but only prints 'slot waiting:' to stderr for a waiter. The gate therefore reads slots.py run --wait / run-walk.py --wait processes holding no slot and running nothing from one ps call; covered by RW13 and RW38.

## Proceeding meanwhile

Committed the gate, its registration, and the CPU-admission recorders in reserve.py and proof-run.py; running the scoped proof next.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260927T192047Z-fb31d4e2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260927T192047Z-fb31d4e2 --disposition "<what you decided or did>"
