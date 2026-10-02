# Escalation: autocheck refuses EVERY commit touching richos/mobile/ at pre-commit since main 50a5bd1bd: its synthetic 'commit being checked' has no Battery-check trailer

- id: `esc-20261001T215610Z-6e9cb1e2`
- raised: 2026-10-01T21:56:10Z
- from: isaac-opus-r3floor1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-r3floor1` (branch `cc/isaac-opus-r3floor1`)
- head: `c6cde6cc94573b9c78b8c9c695e535b9b0b90c11`
- state: **proceeding**
- for: lead

## The question

May I land a one-line autocheck fix on my branch (cc/isaac-opus-r3floor1) as its own commit: the synthetic commit that branch_range() writes carries a Battery-check line saying its real message is judged by the commit-msg hook? Or does another engineer own this fix?

## What was already tried

git commit -F msg (message has a one-line 'Battery-check: NO - ...' trailer) on richos branch cc/isaac-opus-r3floor1 at c6cde6cc9. pre-commit: autocheck.py branch_selection -> branch_range() writes a commit-tree object with message 'autocheck: the commit being checked' (autocheck.py:632) and asks proof-for.sh --gate for base..<that object>; proof-for.sh:229-240 runs battery-check.py on that range, which finds the synthetic commit (one parent, touches richos/mobile/) with no trailer and exits 1 -> proof-for exit 3 -> 'COMMIT REFUSED: a commit touching richos/mobile/ has not answered the battery question'. The real message is never consulted at pre-commit; the commit-msg hook (battery-check.py --message) is the check that reads it. Introduced by 50a5bd1bd (2026-10-01 19:57, 'the merge gate asks about what the branch brings'); autocheck.test.py's fixture proof-for.sh never runs battery-check, so no test saw it. No fix on main.

## Proceeding meanwhile

Adding the minimal fix as a separate commit on my branch, with a test that is red on main, so my iPhone fixes can be committed; the lead can drop that commit if someone else owns autocheck. Not using --no-verify.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T215610Z-6e9cb1e2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T215610Z-6e9cb1e2 --disposition "<what you decided or did>"
