# Escalation: operator_complete belongs in the engine's ECS app adapter, not femcboost scripts/ecs (brief premise)

- id: `esc-20260925T065820Z-e214dddc`
- raised: 2026-09-25T06:58:21Z
- from: zach-opus-openg1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-openg1` (branch `cc/zach-opus-openg1`)
- head: `aaa6ad5d0ff053d77b09a449f5bd8a1d04ed8b81`
- state: **proceeding**
- for: lead

## The question

Confirm: build operator_complete as a verb of richos/engine/ecs/adapters/app.py (spec r1 (c): 'a new verb in the pinned engine's ECS app adapter', the adapter the app calls), not in femcboost scripts/ecs/ as the brief says?

## What was already tried

Read spec r1 lines 257-261 and r3 (c); the app calls richos/engine/ecs/adapters/app.py (runtime.rs:156) and that file already has the sibling host verb complete-obligation; femcboost scripts/ecs is the terminal's shadow adapter, which the app never calls.

## Proceeding meanwhile

Building it in the engine's app adapter as 'operator-complete' (dashed like its siblings), with tests in richos/engine/ecs/tests/test_app.py. femcboost scripts/ecs is untouched.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T065820Z-e214dddc`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T065820Z-e214dddc --disposition "<what you decided or did>"
