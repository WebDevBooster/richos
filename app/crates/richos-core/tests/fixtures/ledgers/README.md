# Ledger fixtures — the shapes a real customer file actually contains

These are **synthetic** ledgers. No line here came out of anybody's conversation, and none
ever will: `richos` is a public repository, so a real ledger — even one reduced to hashes —
does not belong in it.

They are not invented from the type definitions either. Every record shape in
`v1-current.jsonl` was read off the five real `conversation-ledger.jsonl` files on the
author's machine on 2026-09-05 (71 records, 7 distinct event types: `ThreadCreated`,
`PromptReceived`, `TurnStarted`, `AssistantDelta`, `TurnCompleted`, `ActionRecorded`,
`ActionUpdated`) and reproduced field-for-field with the content replaced. Where the real
files disagreed with each other — a `ThreadCreated` with `entity_id`/`person_id` and one
without, a `PromptReceived` with `binding_revision` and one without, an `AssistantDelta`
with `seq` and one without — **both** shapes are here, because both are shapes a shipped
build wrote and every one of them has to keep replaying.

`v1-legacy.jsonl` carries the older shapes the code documents but the current files no
longer contain: pre-entity threads and turns, deltas with no `seq`, an `ActionRecorded`
with no `visibility` and no `turn_id`, and the events the newer surfaces write
(`TurnInterrupted`, `TurnStopped`, `TurnSuperseded`, `SessionRotated`, `ProactiveMessage`,
`HandoffSummaryUpdated`, `ThreadEntityBound`).

## What they are for

`ledger_forward_compat_tests.rs` replays both files and compares the projection against
the `.golden` digest beside them, produced by
`cargo run -p richos-core --example ledger_projection_digest`.

**The goldens were captured at `ccaaf00`, before the tolerant reader existed.** That is
the whole point of them: they are a recording of how the shipped v1.0.0–v1.0.2 reader read
these bytes. Any change to how a ledger is read that alters one character of these files
has changed what a customer's history says, and the test fails.

Regenerate a golden ONLY when the change to the projection is the deliberate point of the
work, and say so in the commit that does it.
