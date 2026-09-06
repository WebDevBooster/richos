# Escalation: session-start-reap-worktrees.test.sh has been RED on main since the erasure-disable, and run-all-tests.sh runs it

- id: `esc-20260906T071535Z-f157abba`
- raised: 2026-09-06T07:15:35Z
- from: zach-opus-cv1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-cv1` (branch `zach-opus-cv1`)
- head: `6420605eff55e40794dface99d70631a1340622a`
- state: **work-complete**
- for: lead

## The question

Who decides what W07/W10/W10b should assert now that the reconciler never reaches removed - the retirement-safety owner, or should I rewrite them to assert retention?

## What was already tried

Ran the same suite from the pre-change engine at f9f4965 (git archive into a temp dir): 3 FAILED, 13 passed, the same three failing identically, so they predate my branch. They assert outcomes the 2026-09-06 erasure-disable removed: W07 wants the member at removed, W10 wants member removed with dead-present=0. W11 was broken by my adoption pass and I fixed it in 6420605 by sandboxing the ownership ledger, which this suite had left pointing at the operator's real path.

## Proceeding meanwhile

My own work is complete and committed on zach-opus-cv1. I did not touch the three cases: deciding what they should now assert is a decision about the retirement contract, not about my change.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T071535Z-f157abba`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T071535Z-f157abba --disposition "<what you decided or did>"
