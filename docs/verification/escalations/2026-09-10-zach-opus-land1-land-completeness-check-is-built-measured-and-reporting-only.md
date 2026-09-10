# Escalation: Land-completeness check is built, measured and reporting-only: arming it is G4 and stays the CEO's call

- id: `esc-20260910T112142Z-183f464a`
- raised: 2026-09-10T11:21:42Z
- from: zach-opus-land1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-land1` (branch `zach-opus-land1`)
- head: `af084ce20957f2e9d34db05e4605d3b393c87d2d`
- state: **work-complete**
- for: ceo

## The question

Flip LAND_COMPLETENESS_ENFORCE from 0 to 1 in engine/orchestration.config, so an incomplete land REFUSES the next land instead of only announcing it?

## What was already tried

G0/G1/G2/G3 all delivered on branch zach-opus-land1. Measured over every orchestrator transcript on this machine, scoped to the ledger epoch: 17.7% of lands would be refused (44 of 249), 7.6% would be refused by a naive version and are exempted because their owner held a running lock, 61% are undecidable and are never refused. Re-derive with engine/scripts/land-completeness-measure.py. Escape hatch is 'land-residue-ack: <worktree> - <reason>', logged and counted back from the third use.

## Proceeding meanwhile

Shipping reporting-only, which is what the plan's G4 requires: it announces an incomplete land and allows it. No restart is needed either way - the check lives inside guard-ci-red-lands.sh, which is already registered, so its body is re-read at every invocation.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T112142Z-183f464a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T112142Z-183f464a --disposition "<what you decided or did>"
