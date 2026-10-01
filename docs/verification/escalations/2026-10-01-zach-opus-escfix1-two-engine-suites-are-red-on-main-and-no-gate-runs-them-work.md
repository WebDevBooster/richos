# Escalation: Two engine suites are red on main and no gate runs them: worker-priority.test.sh and runner-boundaries.test.sh

- id: `esc-20261001T164926Z-d7684bfc`
- raised: 2026-10-01T16:49:26Z
- from: zach-opus-escfix1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-escfix1` (branch `cc/zach-opus-escfix1`)
- head: `43898e76bd20fd8cc3ed3cf0888ff1925e7b6ca6`
- state: **proceeding**
- for: lead

## The question

Who owns making scripts/lib/worker-priority.test.sh and scripts/lib/runner-boundaries.test.sh green again? Any change to scripts/lib/verification-fixture.sh (or their other inputs) will select them and the land gate will refuse.

## What was already tried

A/B on archives of 19deb6d85 and of cc/zach-opus-escfix1: identical failures at both. worker-priority: test_managed_machine_command_takes_the_borrow_lock and test_managed_machine_flags_cannot_skip_admission get rc 75 ('REFUSED before resource wait') because worker_tokens.machine_command refuses without a live verification owner since c4d430847 (2026-09-27 'fail closed before resource waits'); the tests patch managed_policy True but set no owner. runner-boundaries: test_executed_declared_failure_retains_known_red_policy (verify returns 1). Latest proof run that selected worker-priority before today: 2026-09-27. Evidence: /Volumes/E1TB/state/richos/proof-runs/4684ebc6f8a8/20261001T160515Z-c6tzkbsi/10-engine-scripts-lib-worker-priority.test.sh.log and 17-engine-scripts-lib-runner-boundaries.test.sh.log.

## Proceeding meanwhile

I reverted my verification-fixture.sh scratch migration on cc/zach-opus-escfix1 so this land does not select them, and brought the scratch baseline back to 45 by migrating waiver-repetition.mutation.sh instead. I did not touch either red suite: they belong to the verification work of c4d430847, not this branch.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T164926Z-d7684bfc`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T164926Z-d7684bfc --disposition "<what you decided or did>"
