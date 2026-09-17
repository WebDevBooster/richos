# Escalation: The ECS blocker is gone and two conversation turns still serialize on the app's own lock and ledger

- id: `esc-20260917T195400Z-3e9b24be`
- raised: 2026-09-17T19:54:00Z
- from: echo-opus-frontdesk1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-frontdesk1` (branch `cc/echo-opus-frontdesk1`)
- head: `9a8b19a20ddd9d6e5909b27a00c6d8699560e2de`
- state: **proceeding**
- for: lead

## The question

Is the spine-per-thread refactor (per-thread Spine + a shared Ledger) in scope for this slice, or is it slice 3b? Sage's check says do not build it; Frank's says it is the build item; it is the only thing left between residency and two turns at the same instant.

## What was already tried

Landed the engine's half in the app and proved it against the real engine: per-thread seat ceo-thread:<thread_id>, capability-gated on hello, carried on bind/brief/sync-loro-receipts and on the model's MCP scope. tests/two_conversations_at_once_tests.rs has two threads holding turns open at once and both checkpointing, with the legacy single cursor required to FAIL the identical sequence. So the ECS cursor is no longer what serializes conversations. What still does is entirely app-side and I measured it rather than recalling it: (1) src-tauri/src/main.rs AppState holds one Mutex<Spine> and send_message holds it for the whole turn (26 lock sites across main.rs, timeline_view.rs, events.rs, machinery_view.rs, memory.rs, updates.rs); (2) Spine owns ledger: Ledger by value, and Ledger holds the entire in-memory projection - threads, turns, actions, next_revision - replayed from one JSONL file (ledger.rs:727-777), so a second Spine is a second DIVERGENT projection of the same file, not a second conversation. A spine-per-thread therefore needs the Ledger to become shared before it needs anything else. That is the item Frank's finding 1 calls 'the largest one in the spec ... not an afternoon either' and Sage's finding 8 says explicitly not to build ('Do not build a spine per thread for this; it is the largest change anybody could derive from the page and the page does not ask for it').

## Proceeding meanwhile

Today, with everything landed: a message to any thread is accepted and answered on its own thread by its own resident front desk, never refused; if another thread is mid-turn his message is durable immediately and answered at that turn's boundary. The work behind the threads has been genuinely parallel since slice 1. The only remaining difference from simultaneity is that conversation turn B waits for conversation turn A, which Sage's check argues is seconds by construction. I am finishing the slice's remaining obligations - desktop-work.md, the UI runner, the verification record - and I am not starting the refactor without a decision, because a half-done Ledger ownership change is worse on the branch than either end of it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T195400Z-3e9b24be`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T195400Z-3e9b24be --disposition "<what you decided or did>"
