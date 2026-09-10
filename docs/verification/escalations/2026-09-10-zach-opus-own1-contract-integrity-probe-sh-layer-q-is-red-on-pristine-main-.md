# Escalation: contract-integrity-probe.sh Layer Q is red on pristine main, so 'run the probe green' could not be met and is not mine to fix

- id: `esc-20260910T071816Z-12ded8f9`
- raised: 2026-09-10T07:18:16Z
- from: zach-opus-own1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-own1` (branch `zach-opus-own1`)
- head: `79c2d0401061742a44f429bf15a4d78f7b50209f`
- state: **work-complete**
- for: lead

## The question

Who owns contract-integrity-probe.sh Layer Q, whose worktree-reaper functional canary fails identically on pristine main at 8bec9050 and on this branch?

## What was already tried

Established rather than assumed that this branch does not cause it: I ran the probe from the MAIN checkout /Users/alex/ab/richos/engine before writing anything into it and got the identical single failure — 'Q. FUNCTIONAL CANARY DID NOT RUN — a step of the throwaway fixture FAILED. Wiring and hashes alone do not prove recovery; this probe is incomplete.' with 'Integrity probe FAILED — 1 layer(s) broken'. On my branch the probe reports the same one layer and nothing else: Layer C now reads 8 entries and matches after guard-owned-state.sh was added to all four of the probe's own chain inventories, and every other layer including R (49 rooted hooks, byte-identical bootstrap) and M (single registration) is green. Layer Q is the SessionStart worktree-reaper canary and its fixture step fails before any assertion runs, which is a different failure from a reaper that misbehaves. scripts/reap-stale-worktrees.sh and scripts/reconcile-terminal-worktrees.py are explicitly out of my scope this session and other agents hold them.

## Proceeding meanwhile

All three commits are on zach-opus-own1 and the work is complete: owned-state.test.sh 27/27, engine-status.test.sh 16/16, by-reference.test.sh 49/49, unevaluated-payload.test.sh 9/9.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T071816Z-12ded8f9`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T071816Z-12ded8f9 --disposition "<what you decided or did>"
