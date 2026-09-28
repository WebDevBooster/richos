# Escalation: Nightly .27 (the build he is testing): the phone sheet deadlocks on every install; fix is on cc/echo-opus-adopt1 at 1598a5f2

- id: `esc-20260926T121015Z-212dc350`
- raised: 2026-09-26T12:10:15Z
- from: echo-opus-adopt1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-adopt1` (branch `cc/echo-opus-adopt1`)
- head: `1598a5f244da55e400bf7dd5167e4d76d4aa0c0d`
- state: **proceeding**
- for: lead

## The question

Land 1598a5f2 on its own ahead of the rest of this branch, so the next nightly carries it?

## What was already tried

Walking this branch in a test guest (fresh install) the Use Rich from your phone sheet opened empty and stayed empty. A sample of the app showed PhoneRuntime::status waiting on a mutex it already held: phone/mod.rs locked self.rejected twice in one struct literal (rejected and rejected_by), the first guard living to the end of the statement, with running held. Introduced by 6415339e (2026-09-24); nightly .27 source f9b617bd carries both lines. Unit test fails first on the unfixed code (status did not answer in 5 s) and passes after; phone:: 299 passed.

## Proceeding meanwhile

Fix committed on my branch as its own commit (1598a5f2, touches only phone/mod.rs). Continuing with the phone-path adoption proof in the test guest on a bundle that includes it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260926T121015Z-212dc350`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260926T121015Z-212dc350 --disposition "<what you decided or did>"
