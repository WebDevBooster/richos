# Escalation: Two front desks cannot take a turn at once without four ECS engine edits this brief forbids

- id: `esc-20260917T192024Z-191918ec`
- raised: 2026-09-17T19:20:24Z
- from: echo-opus-frontdesk1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-frontdesk1` (branch `cc/echo-opus-frontdesk1`)
- head: `f5157115b50f8c2fc740c2028447262616b79319`
- state: **proceeding**
- for: lead

## The question

For slice 3a/3b: may the CEO's ECS cursor be made per-thread inside richos/engine/ecs (four named sites), or does the front desk stay serialized at the continuity boundary — residency now, simultaneity later?

## What was already tried

Re-derived it in the code rather than from the reviews. The front desk's every turn binds the CEO's single ECS row: native.rs:2146 calls bridge.bind(entity, thread, session, turn, seat=None, "ceo") -> person_id ceo-default. The engine then fences EVERY continuity call on exact equality with that row: ecs/adapters/app.py:45-52 fence() raises ScopeError 'stale app binding' when current_context(seat) != binding, and app.py:135-136 refuses checkpoint/receipt/brief outright when context[person_id] != PERSON_ID. So if thread B binds while thread A's turn is open, A's checkpoint/brief/inspect fail deterministically - not a retryable race: ecs_core.py:171-220 with_fresh_active_fence retries RevisionConflict only and its own docstring says a ScopeError 'is not a race'. Per-thread CEO seats (Frank check finding 4, Sage 9) need ecs/core/ecs_checkpoint.py:15, :79, :152 (bare store.current_context()) and :119-120 TurnScope(..., PERSON_ID), plus app.py:135-136 and :195 identifying his seats positively rather than by the PERSON_ID literal. My footprint is richos/app/** and the brief says 'Do not edit the engine.'

## Proceeding meanwhile

Building everything that does not depend on the answer, and building the honest version of item 3 rather than a racing one: N RESIDENT front desks (a lease per thread, kept alive across switches instead of torn down and re-primed), sends accepted for any thread instead of refused, per-thread turn/queue state, work already parallel per thread from slice 1. Two threads are both answered and neither is destroyed by the other; what they do not do is hold a turn open at the same instant. Named as a fallback in the verification record, with the four engine sites listed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T192024Z-191918ec`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T192024Z-191918ec --disposition "<what you decided or did>"
