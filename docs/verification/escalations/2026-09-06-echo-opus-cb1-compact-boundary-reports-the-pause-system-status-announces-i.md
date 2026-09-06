# Escalation: compact_boundary reports the pause; system/status announces it — a record on main says otherwise

- id: `esc-20260906T123833Z-0ebed295`
- raised: 2026-09-06T12:38:33Z
- from: echo-opus-cb1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-cb1` (branch `echo-opus-cb1`)
- head: `fe3ec7d12a4ab0a394f026f8aca5616c348787c4`
- state: **work-complete**
- for: lead

## The question

Should the sentence in docs/verification/inner-doctrine-opens-2026-09-06/README.md Q1.3 calling compact_boundary 'the only positive notice the app can get' be corrected on main, since it is measurably not the earliest one?

## What was already tried

Timed a real claude 2.1.263 stream frame by frame (docs/verification/compaction-notice-2026-09-06/, drive_compact.py + gaps.py). compact_boundary arrives at the SAME millisecond the silence ends, 38-44s after it began; system/status status=compacting arrives 3ms after the child accepts the prompt and repeats every 30.000s. 48805-5190=43615ms observed against a reported duration_ms of 43611. Built the surface on the status frames; native.rs needed no change, so echo-opus-dr1's file is untouched.

## Proceeding meanwhile

Shipped on branch echo-opus-cb1: the compaction is now a CEO activity row (Making room to keep going), QUIET_AFTER_MS raised 25000->35000 because the wire has two 30-second heartbeats, new browser suite, record committed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T123833Z-0ebed295`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T123833Z-0ebed295 --disposition "<what you decided or did>"
