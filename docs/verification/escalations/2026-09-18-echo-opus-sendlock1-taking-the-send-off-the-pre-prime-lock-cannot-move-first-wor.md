# Escalation: Taking the send off the pre-prime lock cannot move first-words: the 5 s is the prime's own model turn, which his message must queue behind either way

- id: `esc-20260918T195518Z-79f7b0d9`
- raised: 2026-09-18T19:55:18Z
- from: echo-opus-sendlock1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-sendlock1` (branch `cc/echo-opus-sendlock1`)
- head: `4cee7dd75a5a211539af71881c9c2ff0273253bf`
- state: **proceeding**
- for: lead

## The question

The pre-prime is a bet that the CEO is slower than the prime, and Ray lost it. The only shape that actually recovers those seconds is a front desk that is ALREADY primed when a brand-new thread opens (a pre-warmed spare desk adopted by the new thread, primed at launch rather than at first timeline read). Do you want that scoped as its own slice, or is the durability/acceptance half of this one the whole of it?

## What was already tried

Re-derived from the code, not the record. send_message blocks at state.spine.lock() (src-tauri/src/main.rs:846); ready_the_front_desk holds that same guard across prime_front_desk (main.rs:786), which is a whole model turn (spine.rs:3362 -> prepare_request -> prime_lease_if_needed -> Cognition::reprime). After the prime completes there is NO second prime: prime_lease_if_needed returns early on (lease_primed && lease_primed_thread == thread) at spine.rs:3397. So today the contended path costs prime_remainder + turn, and any shape that hands the message to the lease when the prime completes ALSO costs prime_remainder + turn. The lease is serial - one turn at a time is a continuity-design invariant (§3.1), so his prompt cannot overlap the priming turn. Arithmetic on the brief's own numbers: run E prime 2.927 s, send at +0.5 s -> 2.427 s of remainder, + 5.995 s task turn = 8.42 s, against the brief's ceiling of 5.995 + 1 = 6.995 s. On the app's measured numbers (prime 4412 ms) it is ~9.4 s. The brief's proof step 2 is therefore unmeetable by the shape the brief's job step 1 prescribes - not because the fix is wrong, but because the 5 s was never the lock, it was the prime behind the lock.

## Proceeding meanwhile

Building the half that IS real and provable: the Send is accepted in under a millisecond instead of blocking for the prime's remainder, the CEO's words are fsync'd durable at the instant he presses Send (today they live only in the webview for up to 4.4 s and a quit loses them), and they are handed to the lease exactly once, in order, after the prime, with no second prime. Recording the first-words arithmetic honestly as run F rather than asserting an improvement that is not there.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T195518Z-79f7b0d9`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T195518Z-79f7b0d9 --disposition "<what you decided or did>"
