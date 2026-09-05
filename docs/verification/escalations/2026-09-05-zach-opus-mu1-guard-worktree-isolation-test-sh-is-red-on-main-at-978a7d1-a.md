# Escalation: guard-worktree-isolation.test.sh is RED on main at 978a7d1, and it is not from my change

- id: `esc-20260905T185036Z-5ce7e915`
- raised: 2026-09-05T18:50:36Z
- from: zach-opus-mu1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-mu1` (branch `zach-opus-mu1`)
- head: `502fddadd9a575ff4a00f55aa3e0a1948bab51ef`
- state: **work-complete**
- for: lead

## The question

Who takes worktree-spawn-intent.mutation.sh's 3 unproven mutants (externals-dropped/Q02, prepared-not-required/Q04, branch-drift-ignored/Q08) — it is clause-7 territory, not mine?

## What was already tried

Ran the harness from the pristine main checkout /Users/alex/ab/richos/engine: rc=1, 4 of 7 proven. Ran the parent suite from a sandbox copy and from the real tree: identical failure both ways, so it is not a sandbox artifact. externals-dropped reports 'the suite still PASSED without this property' (a genuine coverage gap); prepared-not-required and branch-drift-ignored report 'red but NOT at Q04/Q08' with Q05/Q07/Q09 red instead, which looks like stale needles after a message reword.

## Proceeding meanwhile

My own work is complete and committed on zach-opus-mu1. I did not fix these: they are somebody else's harness and narrowing or widening my scope is not my call. I did make them harmless to mine — both converted harnesses now record the baseline failure set and refuse to score any mutant whose named case was already red, so a pre-existing regression can no longer be borrowed as proof.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260905T185036Z-5ce7e915`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260905T185036Z-5ce7e915 --disposition "<what you decided or did>"
