# Escalation: Brief premise false: the four 'never examined' repositories are already examined and clean; the real defect is one 47-minute test unit

- id: `esc-20260915T093138Z-b67e04e5`
- raised: 2026-09-15T09:31:38Z
- from: zach-opus-ciall1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ciall1` (branch `cc/zach-opus-ciall1`)
- head: `0f2f375a913081a586962be6fb23f909a857fc7d`
- state: **proceeding**
- for: lead

## The question

Do you want the 2811.7s workspace-spec-fourteen.test.sh split into sections (it is a FROZEN round-6 suite and splitting it edits a frozen artifact), or left whole with corrected packing weights and a per-unit timeout?

## What was already tried

Re-ran engine/scripts/ci-status.sh --all: reproduced BENIGN 2, FINDING 4, OK 101, UNDECLARED 6, UNKNOWABLE 7 exactly. Harvested every unit duration from run 34945072758 (run #216) job logs.

## Proceeding meanwhile

Correcting the packing weights, adding a per-unit timeout and weight-drift detection to ci-shard.sh, closing the 6 UNDECLARED axes, and dispositioning the dependabot red.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260915T093138Z-b67e04e5`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260915T093138Z-b67e04e5 --disposition "<what you decided or did>"
