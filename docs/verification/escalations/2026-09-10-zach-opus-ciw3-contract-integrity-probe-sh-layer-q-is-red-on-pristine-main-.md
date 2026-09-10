# Escalation: contract-integrity-probe.sh Layer Q is RED on pristine main, so 'run the probe green' cannot be met by any branch

- id: `esc-20260910T070728Z-1b142fd6`
- raised: 2026-09-10T07:07:28Z
- from: zach-opus-ciw3
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ciw3` (branch `zach-opus-ciw3`)
- head: `b3c42504c53b90fa4e2ce257556901d69e478f66`
- state: **work-complete**
- for: lead

## The question

Who owns repairing Layer Q's reaper functional canary? It is outside my scope and outside every scope I was told not to touch, so nobody currently has it.

## What was already tried

Ran the probe from my worktree (exit 2, Layer Q broken) and then from the pristine main checkout at /Users/alex/ab/richos/engine (exit 2, Layer Q broken, identical text). Diffed the two logs: the ONLY difference is the guard's own path, main vs worktree. Ran scripts/hooks/install.sh first to mint the .sha256 sidecars, which changed nothing about Q. Layer R independently confirms my new guard is wired correctly: 'sourced by all 49 rooted hooks with a byte-identical bootstrap'.

## Proceeding meanwhile

Everything else in the task is complete and committed: the six-axis reader, the one-line status command, the PreToolUse red gate with 14 passing cases, the unattended watch with 9, and declarations on six of the eight richos workflows. Layer Q's canary covers the worktree reaper (scripts/reap-stale-worktrees.sh, scripts/reconcile-terminal-worktrees.py) which my brief explicitly forbade me from touching.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T070728Z-1b142fd6`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T070728Z-1b142fd6 --disposition "<what you decided or did>"
