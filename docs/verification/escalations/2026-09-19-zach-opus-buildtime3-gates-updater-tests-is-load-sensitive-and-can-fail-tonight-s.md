# Escalation: gates/updater-tests is load-sensitive and can fail tonight's nightly on its own: an fd inherited across fork holds another test thread's session lock

- id: `esc-20260919T232223Z-98784a43`
- raised: 2026-09-19T23:22:23Z
- from: zach-opus-buildtime3
- worktree: `/Users/alex/ab/richos-wt/zach-opus-buildtime3` (branch `cc/zach-opus-buildtime3`)
- head: `481ec7c2009ac760d014b8b0f68a286c50a3b242`
- state: **work-complete**
- for: lead

## The question

Who owns the fix to probe()'s fork window in richos/app/crates/richos-user-update/src/lib.rs — it is product code, not build tooling, and my brief said to leave it if the lock is not machine-global?

## What was already tried

Reproduced three times, each a different test. Two copies of the SAME compiled test binary at once, 8 threads each: A green, B red (installs_as_actual_owner_and_replays_exact_receipt, WouldBlock 'another RichOS session is running'). The same two concurrent processes with --test-threads 1: BOTH GREEN. So the lock is NOT machine-global (every test home is its own tempfile::tempdir); it needs several test threads inside one process, and a second process only supplies the load. probe() forks a child that inherits every descriptor until its pre_exec marks them close-on-exec, so a probe forked by one thread can hold another thread's session.lock open, and Lock::acquire_startup gives up after 5 s.

## Proceeding meanwhile

My own brief's items are done and committed on cc/zach-opus-buildtime3: the self-test is hermetic and its assertions cannot lose a match to their own plumbing; script-suites green. This gate runs BEFORE script-suites in gates(), so tonight's nightly can still stop there without anything being wrong with the tree.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T232223Z-98784a43`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T232223Z-98784a43 --disposition "<what you decided or did>"
