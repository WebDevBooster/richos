# Escalation: The worktree-removal guard is NOT broken: WTR1's six CI failures are mutant kills, and the residue is the known WTI1-class harness flake

- id: `esc-20260914T101742Z-e01f7d24`
- raised: 2026-09-14T10:17:42Z
- from: tom-opus-w1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-w1` (branch `cc/tom-opus-w1`)
- head: `9bc45c3e349faca367b27d4b4efeb52aea3be267`
- state: **work-complete**
- for: lead

## The question

The open WTI1 flake escalation (esc-20260913T224044Z-13ca1557) is scoped to ONE harness; it now provably affects WTR1 too. Should it be rescoped to the shared check() helper across all mutation harnesses, and owned by someone now?

## What was already tried

Two premises in my brief were false. (1) 'expected exit 2, got 0 means the guard did not refuse': those five lines are indented INSIDE the harness report - they are mutant M12's kills and are the DESIRED outcome. The only real failure is 'UNPROVEN M12 <- red but NOT at: S3', the exact signature zach-opus-ci4 escalated 2026-09-13. (2) '9bc45c3e provisioned 21 missing dependencies and may have fixed this': the diff c25a8426..9bc45c3e has ZERO deleted lines and guard-worktree-removal.mutation.sh is byte-identical (sha256 692e8086), so nothing on the WTR path changed. Evidence: hand-verified the SHIPPED guard OUTSIDE the suite against REAL workspaces - S1/S2/S3/S4 shapes all exit 2 (refuse) even WITH a worktree-remove-ack, negative control (ordinary dir) exits 0; the guard's own behavioral suite exits 0 at main; WTR is green at main (PASS WTR1, exit 3). Ruled out SIGPIPE/pipefail in check() (700 iterations, idle and 48-way oversubscribed, zero false misses at the real 11KB output size) and pool output interleaving (per-slot files drained in submission order).

## Proceeding meanwhile

Green-at-main is the flake not reproducing, NOT a fix - so WTR must not be recorded as fixed. No code change made: weakening the assertion would be the wrong fix and the guard itself is sound.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T101742Z-e01f7d24`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T101742Z-e01f7d24 --disposition "<what you decided or did>"
