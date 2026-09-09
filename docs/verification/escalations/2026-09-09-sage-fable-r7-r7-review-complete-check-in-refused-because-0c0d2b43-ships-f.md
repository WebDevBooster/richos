# Escalation: r7 review complete; check-in refused because 0c0d2b43 ships four dangling public citations in evidence-r7/review-r6.md

- id: `esc-20260909T161740Z-ea4ac93c`
- raised: 2026-09-09T16:17:40Z
- from: sage-fable-r7
- worktree: `/Users/alex/ab/richos-wt/sage-fable-r7` (branch `sage-fable-r7`)
- head: `0c0d2b430532f0695e5668b9fa775e97a4323f3a`
- state: **stopped**
- for: lead

## The question

Should Codex rewrite the four checks/ citations in docs/verification/owned-outcome/evidence-r7/review-r6.md to ../evidence-r6/checks/... and re-index that file's sha256 in artifact-index.json, after which I check my review in on top, or do you want the review taken from my worktree as it stands?

## What was already tried

Brought the r1, r4, r5 and r6 Sage reviews into this tree byte-identical to main, which clears the three findings that are artifacts of this tree's base; reran engine/scripts/publication-completeness.sh --explain on this tree: exactly four findings remain, all from the revision's copy of the r6 review citing checks/docs-claims.log, checks/echo-ownership-fence.log, checks/echo-recovery-review.log and checks/engine-final-result.json, which live in evidence-r6/checks/. Review only, so I did not edit the revision's file (verify-evidence.py asserts its bytes) and did not add an exemption line (it would carry the defect to main green). The land's own check-in is not gated but the following upload from the main checkout is.

## Proceeding meanwhile

The review is written and on disk at docs/reviews/sage-fable-r7-owned-outcome-2026-09-09.md in /Users/alex/ab/richos-wt/sage-fable-r7 (in the index, not yet recorded), with the defect named as condition C12; verdict ACCEPT WITH NAMED CONDITIONS; C3, C10 and C11 closed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260909T161740Z-ea4ac93c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260909T161740Z-ea4ac93c --disposition "<what you decided or did>"
