# Escalation: publication-completeness now refuses every commit in a richos worktree: richos-hq tools-private/operator/test_cutover.sh (changed 18:34 local) reads .row-currency and carries no instance-mechanism line

- id: `esc-20260928T173707Z-37f98f18`
- raised: 2026-09-28T17:37:07Z
- from: zach-opus-procgen1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-procgen1` (branch `cc/zach-opus-procgen1`)
- head: `4e456a41b7c8dce675d1cb2cd1471e4b152cc319`
- state: **proceeding**
- for: lead

## The question

Can the owner of richos-hq tools-private/operator/test_cutover.sh add its instance-mechanism line (or move it), so commits in richos worktrees are admitted again? My last commit on cc/zach-opus-procgen1 (the verification-dependencies.json repin that proof-evidence requires for the proc_tree fix) is staged and refused until then.

## What was already tried

publication-completeness.sh --explain on my worktree names only that one private-tree file; my diff touches no published claim; main has no exemption for it; my commits at about 17:25Z were admitted, before that file changed.

## Proceeding meanwhile

Running the owning proof suites twice on the working tree (repin included) and retrying the commit after each pass. Commits 9dbf60cc, d036f31f and the ci-shard.test.sh isolation fix are already on the branch.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260928T173707Z-37f98f18`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260928T173707Z-37f98f18 --disposition "<what you decided or did>"
