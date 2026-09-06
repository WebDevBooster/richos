# Escalation: The named hook is innocent; two OTHER SessionStart hooks really do block, and 9b fails on a timing budget

- id: `esc-20260905T105053Z-352120d3`
- raised: 2026-09-05T10:50:53Z
- from: zach-opus-st1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-st1` (branch `zach-opus-st1`)
- head: `41f1696ec52982cf808472c9c68a77a833615da7`
- state: **proceeding**
- for: lead

## The question

Case 9b's failure message is a wrong diagnosis (the hook never reads its own stdin; the reaper sweep just costs 8.15-8.48s against an 8s window). Your brief says 'if the hook is innocent and the test is wrong, change neither', but your rules say 9b should go green. Do you want hang_check taught to tell BLOCKED from SLOW via a closed-stdin control arm (makes 9b green for the right reason, strengthens the assertion), or 9b left red pending your call?

## What was already tried

Reproduced 9b on unmodified main; timed the hook at 8s closed-stdin vs 10s open-stdin inside the real test sandbox; timed the reaper sweep 5x at 8150-8479ms with stdin closed; read line 111 in context (its stdin is the printf pipe, not the hook's); measured the shipped binary 2.1.261 (payload arrives on a socketpair, EOF in 3-6ms) and measured a genuinely blocking SessionStart hook holding a whole session for 602s with no rescue timeout.

## Proceeding meanwhile

Fixing the two SessionStart hooks that DO block unconditionally and are untested in their hook-firing form: snapshot-enforcing-hooks.sh (no hang case at all) and snapshot-agent-definitions.sh without --session (case 9c only covers the --session form, which cannot reach the read). Adding failing-first cases for both.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T105053Z-352120d3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T105053Z-352120d3 --disposition "<what you decided or did>"
