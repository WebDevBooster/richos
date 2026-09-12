# Escalation: Deleting the integration floor makes recording the branch an operational precondition: unrecorded repositories attribute no created refs

- id: `esc-20260912T112834Z-91a77eef`
- raised: 2026-09-12T11:28:34Z
- from: zach-opus-g2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-g2` (branch `cc/zach-opus-g2`)
- head: `c833cb6c0d592e0a21a783b51ff4ab1e155aabfe`
- state: **work-complete**
- for: lead

## The question

Before the next spawn in richos, does Rich run 'workspaces.sh integration --repo /Users/alex/ab/richos --branch dev/workspace-spec --why <this work>' (and the same for femcboost), given that with no record a ref an agent creates is not attributed at all and is left behind after a later land?

## What was already tried

Both items are done, committed and green (52 unit / 47 e2e / 38 mutants / 165 / 94 / 19+10 / 7-of-7 / my own 5-of-5, red 0-of-5 at 84e12d32). I did NOT paper over the gap in code: attribution needs a recorded target to measure 'at stake' against, and inventing one without it is the guess point 14 forbids. The observation that cannot be made is now recorded as 'attribution-skipped' in events.jsonl, naming the refs and the command that cures it, so it is auditable rather than silent.

## Proceeding meanwhile

Nothing. Work complete on branch cc/zach-opus-g2; nothing installed, merged or pushed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260912T112834Z-91a77eef`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260912T112834Z-91a77eef --disposition "<what you decided or did>"
