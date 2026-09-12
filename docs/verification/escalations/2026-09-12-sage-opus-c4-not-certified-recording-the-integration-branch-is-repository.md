# Escalation: NOT CERTIFIED: recording the integration branch is repository-wide and reaches backwards, so two bodies of work in one repository collide

- id: `esc-20260912T115632Z-9874e348`
- raised: 2026-09-12T11:56:32Z
- from: sage-opus-c4
- worktree: `/Users/alex/ab/richos-wt/sage-opus-c4` (branch `cc/sage-opus-c4`)
- head: `1dde5c028a7907668642d0429b44ba171c18125a`
- state: **work-complete**
- for: lead

## The question

Before recording dev/workspace-spec for /Users/alex/ab/richos, whose call is it that every OTHER body of work in that repository (the five codex ones, and anything landing to main) will then be judged against that branch, and that recording main back afterwards refuses this round's own unlanded agents?

## What was already tried

Certification of cc/zach-opus-g2 @ 2bc413df is committed on cc/sage-opus-c4 at 1dde5c02. Both items hold; the refusal rests on D3, reproduced green at 84e12d32 and red here: the integration record is one slot per repository, read live at land time, so recording the next body of work's branch moves the target of an unlanded agent of the previous one - land REFUSED, workspace left behind, point 5 blocked. The superseded record goes to integration.json 'history', which nothing reads.

## Proceeding meanwhile

Nothing. The certification is complete and committed; nothing installed, merged or pushed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260912T115632Z-9874e348`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260912T115632Z-9874e348 --disposition "<what you decided or did>"
