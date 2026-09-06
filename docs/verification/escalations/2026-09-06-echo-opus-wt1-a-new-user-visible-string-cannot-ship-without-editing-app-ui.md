# Escalation: A new user-visible string cannot ship without editing app/ui/tests/lib/state-registry.js, which my brief put out of bounds

- id: `esc-20260906T053512Z-4b38032c`
- raised: 2026-09-06T05:35:12Z
- from: echo-opus-wt1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-wt1` (branch `echo-opus-wt1`)
- head: `1c3e54293169bd5d9d2fca40ff7eada4ab420c3c`
- state: **work-complete**
- for: lead

## The question

Is state-registry.js in scope for an engineer adding UI copy while tom-opus-bs1 owns app/ui/tests/**, or should the eight rows be handed to tom to land separately?

## What was already tried

Verified the collision rather than assuming it: affordances.js was green at 934f127; adding the waiting band's eight strings turned three of its checks red with 'NEW USER-VISIBLE STATE, NOT CLASSIFIED' naming all eight by file and line; adding the rows turned it green again. Kept the edit strictly additive in one fenced block at the end of the file so it merges against any edit tom makes elsewhere in it.

## Proceeding meanwhile

Landed the rows on echo-opus-wt1 (1c3e542) rather than shipping a red suite, and said so in that commit message. Everything else in the task is complete.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T053512Z-4b38032c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T053512Z-4b38032c --disposition "<what you decided or did>"
