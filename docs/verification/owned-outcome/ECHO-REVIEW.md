# Echo: registration recovery and escalation review

Reviewed the worktree implementation of `registration.rs`, `owned_work.rs` and
`autonomy.rs`. Scope is durable intake, preservation of CEO instructions and the
independent escalation challenge. This is not a signoff on unattended real-model
performance or installed deployment.

## Corrected in this review

The escalation challenge accepted every deserialized `decision`, including empty
questions, authority explanations and options. It then discarded that second
review and returned the original proposal. A challenge that corrected the missing
authority could therefore still present the CEO with the rejected routine question.

`autonomy::verify` now requires a nonempty question, missing-authority explanation
and recommendation plus at least two nonempty options from the challenge. It
returns that validated final decision. An unusable challenge yields a review-retry
error, which cannot become either a completion claim or a CEO decision.

Validation: built the actual `richos-run` binary using
`/Users/alex/.cargo/bin/cargo build -p richos-core --bin richos-run --manifest-path app/Cargo.toml`.
Ran `python3 app/scripts/test-owned-escalation.py`: **11 cases passed** through the
real native protocol and `audit-session` command using a scripted provider.
Cases cover rejection of a routine question, correction of a proposed escalation,
completion and eight malformed final outcomes. Both reviews retain the original
publication prohibition. The corrected-authority case requires the exact new
question, rationale, recommendation and options, so returning the old proposal
fails the test.

Raw evidence from this review is in
`/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-escalation-test-nqrb0331/`.
These are deterministic protocol tests, not evidence that a real model reliably
makes the right authority judgment.

## Necessary connected fixes handed to the other reviewer

- Reserve the persisted retry timestamp before inference. Otherwise a crash after
  charging the attempt leaves an already-due timestamp and repeated restarts can
  bypass the documented hourly recovery pace. Sage owns this change.
- An interrupted turn can contain an authorized CEO request and no Rich reply.
  Requiring a nonempty quote from that empty reply makes every future registration
  attempt fail on identical bytes. Sage owns the narrow absence-of-commitment case.
- A correction must preserve an explicit user pause. The desktop conversation
  amendment previously deleted the pause marker and `RunController::amend` clears
  the snapshot pause. Root authorized preserving explicit pause while keeping live
  correction's temporary writer interruption resumable. Sage owns desktop changes.
  Echo added `RunController::amend_with_pause` to persist the corrected plan, receipt
  and desired pause in one journal append. Saving amendment then pause separately
  had a crash window where restart could execute paused work. Existing `amend`
  callers retain their behavior. Two new core tests check the single append,
  restart, receipt replay, no execution while paused and live correction resumption.
  Full `cargo test -p richos-core --test run_tests`: **44 passed, zero failed**.

Sage independently found pending-request amendment/cancel targeting and repeated
amendment scope retention issues. Those remain in Sage's review and test scope.

No unrelated improvements were implemented. No production checkout was changed,
no commit was created and no merge, push or deployment was performed by this reviewer.
