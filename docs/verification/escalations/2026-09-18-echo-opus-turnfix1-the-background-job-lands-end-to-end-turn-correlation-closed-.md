# Escalation: The background job lands end to end: turn correlation closed esc-20260918T211207Z-52acb812

- id: `esc-20260918T221347Z-1bf000e7`
- raised: 2026-09-18T22:13:47Z
- from: echo-opus-turnfix1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-turnfix1` (branch `cc/echo-opus-turnfix1`)
- head: `3a95d63efdbbcd7a1b6783b2d2dfc80ff9bc5258`
- state: **work-complete**
- for: lead

## The question

Nothing is blocked. Do you want the turn-correlation change walked on a nightly before it is treated as the candidate's land path, or is the probe's own land enough?

## What was already tried

One real-provider work_lease_roundtrip run (the granted third): fixture main moved 896df5f9 -> 200376ac, notes.txt changed, mcp__richos_work__integrate at journal rows 77-78, mcp__richos_work__complete at 81-82, Settled at t+192.148s with the CEO-facing notice 'It landed on main in qa-fixture. An independent review passed it first.' The lease ran seven turns; the host sent three. Record: docs/verification/turn-correlation-2026-09-18.md on branch cc/echo-opus-turnfix1.

## Proceeding meanwhile

Nothing outstanding on this slice; four commits on cc/echo-opus-turnfix1, suites green.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T221347Z-1bf000e7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T221347Z-1bf000e7 --disposition "<what you decided or did>"
