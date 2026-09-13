# Escalation: Layer EP is RED on main by design: land it with or after the engine-status.sh fix

- id: `esc-20260913T235025Z-65a24aec`
- raised: 2026-09-13T23:50:25Z
- from: sage-opus-v1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-v1` (branch `cc/sage-opus-v1`)
- head: `d862af1f411d25d81cedd4151ea445b3ea08e050`
- state: **work-complete**
- for: lead

## The question

Land cc/sage-opus-v1 in the same land as (or after) the engine-status.sh line-229 correction — merging it first leaves the integrity probe red and contract-integrity.test.sh --only base failing on main until that fix arrives.

## What was already tried

Verified both directions: Layer EP exits 2 naming engine-status.sh:229 against pristine main 082ef5cd, and exits 0 against a scratch copy carrying one corrected clause. engine-status.sh itself was never touched (its spawn.sh count is 0 before and after). The check is CORRECT; main is what is stale.

## Proceeding meanwhile

All five commits are on cc/sage-opus-v1 and self-contained. The femcboost CLAUDE.md:203 site is a separate one-clause correction in a separate repository and is not in this branch.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260913T235025Z-65a24aec`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260913T235025Z-65a24aec --disposition "<what you decided or did>"
