# Escalation: Gate timeout/end is NOT RUN BY DESIGN since 2026-09-30; refusing it reverses a recorded land decision

- id: `esc-20261001T163203Z-32da164d`
- raised: 2026-10-01T16:32:03Z
- from: zach-sonnet-gatetimeout1
- worktree: `/Users/alex/ab/richos-wt/zach-sonnet-gatetimeout1` (branch `cc/zach-sonnet-gatetimeout1`)
- head: `7af4c981eda41e2d912ef48e596db2bd1ba772de`
- state: **stopped**
- for: lead

## The question

Reverse the 2026-09-30 land decision for owning checks whose state is `timed-out` or `cancelled` (refuse the land, name the unit, say re-run it alone)? Cost: autocheck/README.md line 164 shows a 905 s gate where 19 checks ended at the 900 s cap, so heavy lands on a busy Mac would be refused until retried (a retry resumes and reuses passes). Alternative: refuse only those two states and keep not-admitted and controller-stopped states NOT RUN.

## What was already tried

Found the cause. richos/app/scripts/autocheck/autocheck.py land_verdict() lines 987-1031: any state other than passed, failed, blocked or invalid is routed by NOT_RUN_WHY (lines 974-981: `timed-out`, `cancelled`, not-admitted, contained, resource-envelope-exceeded, infrastructure-failed, cleanup-failed, scheduler-starvation, resource-recovery-exhausted) into not_run, which is non-blocking; the refusal at lines 942-950 fires only on blocking rows; the allowed-with-NOT-RUN verdict prints at 958-968. proof-run.py:1860 prints the 'did NOT pass' summary. autocheck/README.md lines 175-190 states: no NOT RUN refuses the land, each is named (since 2026-09-30). So the brief premise of an unintended hole is false: it is documented design, and item 3 (the other NOT-RUN states) has the same shape. No code changed.

## Proceeding meanwhile

Nothing changed, worktree clean. On your word I implement: block `timed-out`/`cancelled` (optionally the other no-verdict states) in land_verdict with a refusal naming the unit and saying re-run it alone, a red/green test in autocheck.test.py, README update.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T163203Z-32da164d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T163203Z-32da164d --disposition "<what you decided or did>"
