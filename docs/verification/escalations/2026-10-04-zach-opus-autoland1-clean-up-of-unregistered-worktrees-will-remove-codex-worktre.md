# Escalation: Clean-up of unregistered worktrees will remove codex/ worktrees, which spec point 2 says are never touched

- id: `esc-20261004T210626Z-f65f3e3b`
- raised: 2026-10-04T21:06:26Z
- from: zach-opus-autoland1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-autoland1` (branch `cc/zach-opus-autoland1`)
- head: `34c54f9f4e33f8fca1a0c1828cb9d16c854a7fac`
- state: **proceeding**
- for: lead

## The question

The lead's second addition asks the Mega Lander to remove any unregistered worktree of richos, richos-hq or femcboost that is clean, has its HEAD in main and is idle 24 hours; almost all of them are Codex's codex/* worktrees. The CEO's workspace spec point 2 (workspaces.py) says codex/ is never touched. Is this addition the CEO's amendment of point 2 for worktrees only?

## What was already tried

Built it as the narrowest touch: only the worktree directory is removed with a plain git worktree remove (no force, so git itself refuses anything unclean); no codex/ branch is ever deleted; locked worktrees, worktrees with a process working in them and ~/.richos-nightly/* are skipped.

## Proceeding meanwhile

Proceeding with that implementation on cc/zach-opus-autoland1. If point 2 must stand, the sweep keeps everything except the codex/ case and one line in _sweep_candidates excludes codex/.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261004T210626Z-f65f3e3b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261004T210626Z-f65f3e3b --disposition "<what you decided or did>"
