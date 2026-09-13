# Escalation: engine-self-verify: the MT/ceiling contradiction in my brief is false, and one red is this Mac's launchd, not the engine

- id: `esc-20260913T195606Z-716107f1`
- raised: 2026-09-13T19:56:06Z
- from: zach-opus-ci3
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ci3` (branch `cc/zach-opus-ci3`)
- head: `1e0d18faa6c712ee66c556babf64ea312a8e4831`
- state: **work-complete**
- for: lead

## The question

Before you run ci-verify here: do you want me to leave Q7 to your install.sh run from the main checkout, or is somebody else clearing the retired launchd reconciler?

## What was already tried

Re-ran the MT canary's two legs standalone against guard-worktree-isolation.sh at a6a9e888: the fable leg exits 2 at CLAUSE 7 (registration at spawn, no recorded body of work), never reaches clause 6, and never mentions a tier. Layer MC passes on the same run. guard-model-ceiling.sh is a separate hook the MT canary does not invoke, so the two do not contradict each other and MODEL_CEILING="opus" is untouched. Root cause for BOTH item 1 and item 2 is eedfbc7d (2026-09-12), which made registration refuse a repository with no recorded integration branch and updated no consumer. Scope was 27 red units, not 3; all 27 are green on the branch.

## Proceeding meanwhile

Branch cc/zach-opus-ci3, 9 commits. scripts/ci-verify.sh --no-suites exits 0 under CI conditions (launchctl off PATH, which is the Linux runner's own state). It exits 1 on this Mac for ONE reason: Q7, com.richos.worktree-reconciler still loaded under launchd here. That layer is guarded on uname=Darwin so it cannot fire in CI, and install.sh REFUSES to touch launchd from a worktree by design, so it is your step from the main checkout. Also: the land needs scripts/hooks/install.sh afterwards, because .claude/settings.local.json gained a registration and its sidecars are gitignored.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260913T195606Z-716107f1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260913T195606Z-716107f1 --disposition "<what you decided or did>"
