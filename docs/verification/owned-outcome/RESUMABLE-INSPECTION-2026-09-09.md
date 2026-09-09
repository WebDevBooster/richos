# Resumable inspection repair

Scope: the installed native Claude Code outcome checker. This repairs the long-history timeout and restart behavior left open by LIVE-EXIT-REPAIR-2026-09-09.md. It adds no business assignments, skills, worker permissions or UI features.

## Failure and correction

The previous repair bounded the initial prompt and stopped infrastructure errors from blocking native exit. It did not preserve inspection work when the inspector reached its time limit. New source activity therefore paid for another inspection that started from the beginning. Narrow fixture success did not establish that the reported conversation could be inspected. Reporting the integration as finished on that evidence was wrong.

The checker now owns one private checkpoint per canonical workspace. It retains the inspector's native conversation UUID, successful source-page read receipts, inspected file hashes and any pending decision review. Each bounded native process resumes that exact conversation. Its permissions remain read-only, with the current evidence directory explicitly accessible and configured workspace settings retained.

A time slice is host scheduling progress, not a model verdict. The Python adapter continues automatically, without waking the worker, using another business retry or asking the user to restart anything. Three consecutive slices with no new durable tool evidence stop as a cached, nonblocking inspection failure. Reading the same content again does not reset that stall count. Provider errors are still errors, never completion evidence.

New source invalidates old verdicts and proposed decisions while retaining the conversation and receipts for unchanged page bytes. Source coverage is checked against the current snapshot. The next required page batch is bounded, avoiding an enormous list of paths in the prompt. Changed or deleted inspected files invalidate cached results. Changes detected before publication require another slice.

The host saves checkpoints atomically with private permissions. Workspace inference and journal locks remain held by a surviving native child if its parent dies. A crash before the first native prompt is recoverable only when Claude reports that exact UUID missing and disk inspection confirms there is no transcript. An existing or damaged transcript is never silently replaced by a fresh inspection.

Normal Claude Code exit retains the previous repair's nonblocking behavior for infrastructure failures. A valid incomplete verdict still sends the worker the specific unfinished requirements through the existing continuation path. This is not an assertion that the underlying business work is complete.

## Validation

The full Rust core test command ran 47 test targets/doc-test groups: 1,123 passed, zero failed and five ignored. The Python adapter's 139 existing tests and six new progress tests pass. New coverage includes automatic continuation, restart, unchanged failure suppression, source corrections, lost ownership, durable read receipts, artifact changes and inherited process locks.

Actual native-process tests verified continuation under the same UUID: a second process correctly used an inventory count supplied only to the first process. A separate test killed the initial process before its first prompt, proved that no native transcript existed and successfully recovered under the same UUID.

The reported session was replayed read-only from a frozen copy containing 87 messages and approximately 2.56 MB of retained audit data. A deliberately short first slice saved 17 source receipts. The second reached all 41 required source/context pages. The third made no new durable progress. The fourth returned a concrete incomplete verdict. All four used the same native UUID, with no duplicate source-page Read calls. No production ownership record was marked complete and no business work was executed by the replay.

That development replay overlapped compilation as crash/lease edge cases were corrected. Its per-slice receipts are retained rather than presented as one immutable release-binary run. Installed validation is recorded separately below.

The verdict identified unfinished authorized work. It also explicitly disclosed that artifacts in other repositories were outside its read scope. That limitation is not evidence that those artifacts failed and this repair does not claim that every business deliverable in the conversation passed inspection.

Private transcripts, snapshots and test receipts are retained under `/Users/alex/.codex/artifacts/resumable-inspector-20260909`. They are not committed to the public repository.

## Remaining boundary

This is a checkpoint and continuation repair, not a guarantee against provider outages or arbitrary model mistakes. An actual provider failure or a repeatedly stalled inspector remains visibly unverified and permits normal native exit. There is no infrastructure-failure instruction telling the leader to repair the checker, no automatic certification and no unchanged-input retry loop.
