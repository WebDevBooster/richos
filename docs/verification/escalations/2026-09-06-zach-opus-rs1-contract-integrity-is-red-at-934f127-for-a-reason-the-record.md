# Escalation: contract-integrity is red at 934f127 for a reason the record does not name: probe Layer Q asserts a contract that a6c076c retired one hour before this session

- id: `esc-20260906T045828Z-ff83c1e6`
- raised: 2026-09-06T04:58:28Z
- from: zach-opus-rs1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-rs1` (branch `zach-opus-rs1`)
- head: `934f127abd817771ec5d1d36f88d97ac0dd3e99b`
- state: **proceeding**
- for: lead

## The question

Is the a6c076c retention contract (the reconciler captures and verifies, then RETAINS the quarantine and its Git registration; verified is terminal; erasure refused as exclusive-access-unavailable) the intended permanent contract, so probe Layer Q should be updated to assert THAT, or did a6c076c gut crash recovery, making Layer Q correctly red?

## What was already tried

Ran scripts/hooks/contract-integrity.test.sh whole on macOS at 934f127: 12 FAILs by line 81 and still running, every one shaped N.something-probe-passes (expected exit=0 got=2). Re-ran with --only base and CI_PROBE_DEBUG=1: ALL of them share ONE root cause, the probe Layer Q, which reports: the session-start wrapper did NOT recover a terminal transaction left at quarantined (member state verified, quarantine present). That is not a defect in the wrapper. Commit a6c076c (2026-09-06 04:35, engine/docs/workspace-retirement-safety.md plus reconcile-terminal-worktrees.py) DELIBERATELY made this the new behavior: unregister_member and remove_member now raise BlockedFailure exclusive-access-unavailable: automatic erasure is disabled; quarantine and Git registration are retained. So verified is now the terminal member state. contract-integrity-probe.sh was NOT in the a6c076c diff, so Layer Q still asserts state == removed and quarantine gone. My brief said contract-integrity was red at cases 54 and IN2 - that was measured at fc56c20, 429 commits ago, and is no longer the failure.

## Proceeding meanwhile

Proceeding on the other four suites. provision-claude-md.test.sh is ALREADY GREEN at 934f127 (37 of 37, 0.7s) - fixed by 0b6842a and eb70a5a after the record was written, so that premise is stale too. guard-worktree-isolation.test.sh reproduced exactly as recorded and is fixed on my branch. Not touching reconcile-terminal-worktrees.py or the residue path, which is the live area of zach-opus-fx1 and the source of this change.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T045828Z-ff83c1e6`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T045828Z-ff83c1e6 --disposition "<what you decided or did>"
