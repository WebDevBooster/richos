# Escalation: Two of the four red CI suites are contract regressions in the worktree-lifecycle work, not portability — they need their owner, not CI

- id: `esc-20260910T003507Z-7907752b`
- raised: 2026-09-10T00:35:07Z
- from: zach-opus-ci2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ci2` (branch `zach-opus-ci2`)
- head: `4f01e5c73ea1a8da58fa6e0b76541e3c0860237b`
- state: **proceeding**
- for: lead

## The question

Who re-specifies shell-worktree-sparse.test.sh (invalidated by 6472bb60) and terminalize-agent-worktrees.test.sh (invalidated by 2afb9703), and is 2026-09-24 an acceptable expiry on the declared tolerance?

## What was already tried

Reproduced all four reds on Linux in an ubuntu:24.04 container AND on macOS, then bisected both by execution. shell-worktree-sparse.test.sh: 21/21 pass at 6472bb60^, 6 fail at HEAD. terminalize-agent-worktrees.test.sh: 42/42 pass at 2afb9703^, 11 fail at HEAD. Both red IDENTICALLY on macOS and Linux, so neither is a portability finding and neither is a CI problem. 6472bb60 made every native member carry cleanup_owner=claude-code and taught shell-worktree-sparse.eligible() to refuse such a member; 2afb9703 introduced cleanup_policy=integrated-daily and changed which members take the save_ref+quarantine route. Neither commit updated the suite it invalidated. The OTHER two reds were genuine Linux portability defects and I fixed both, verified green on Linux and macOS.

## Proceeding meanwhile

Proceeding on all five brief items. The two regressions are DECLARED in engine/scripts/lib/ci-known-red.tsv with the breaking commit, the failing case names, one sentence on what would un-skip each, and an expiry of 2026-09-24 — declared, not skipped: a declared unit that PASSES fails the build (negative control) and an entry past its expiry fails the build. Restoring the push trigger does not wait on this answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T003507Z-7907752b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T003507Z-7907752b --disposition "<what you decided or did>"
