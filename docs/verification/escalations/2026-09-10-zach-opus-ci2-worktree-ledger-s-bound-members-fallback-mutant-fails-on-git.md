# Escalation: worktree-ledger's bound-members-fallback mutant fails on git 2.55 — which is what every GitHub runner ships

- id: `esc-20260910T033915Z-df18e8fe`
- raised: 2026-09-10T03:39:15Z
- from: zach-opus-ci2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ci2` (branch `zach-opus-ci2`)
- head: `3a0c6925dfdf98e0ef2fc3f2fd79c1df3fd71b46`
- state: **work-complete**
- for: lead

## The question

Who takes the worktree-ledger read_all() divergence on git >= 2.55? It is lifecycle internals, which your 2026-09-10 ruling put off-limits to the CI side, and it is declared with a 2026-09-24 expiry rather than fixed.

## What was already tried

Isolated to ONE variable by execution. Same ubuntu:24.04 image, same tree, only the git version differs: with 2.43 the mutant passes (removing the fallback turns L28 red, as the harness expects); with 2.55 from the git-core PPA it fails — L29 goes red returning [] and L28 does not. Green on macOS git 2.52 too, so the boundary is between 2.52 and 2.55. GitHub's ubuntu-latest ships 2.55.0, confirmed from run 34432651037's own log. The BASE suite passes 37/37 everywhere; only the mutation harness catches it, which is the harness earning its cost. Mechanism as far as I took it: the bound-members-fallback mutant forces the registration fallback unconditionally, and under 2.55 that returns [] for the L29 fixture where under 2.43 it returns registrations — so read_all() yields no registration for that fixture under the newer git. I did not go further into worktree-ledger.py or worktree-transactions.py because your ruling put that code off-limits to me. Ruled out first, each by execution rather than by argument: not a flake (seen twice on the runner, shards 11 and 4, on different commits), not an ordering interaction from sharding (the whole of shard 11 in the same order is green on Linux), not TMPDIR shape (plain, real, symlinked and the runner's own layout all pass), and not the seal itself (a hand-built fixture seals a correctly bound native member under 2.55).

## Proceeding meanwhile

Declared in engine/scripts/lib/ci-known-red.tsv with an expiry of 2026-09-24, so CI is green on the runner and the row is printed on every run. It needed a new capability the table did not have: a seventh column giving a shell predicate for WHERE a row applies. An unconditional row would have been right on the runner and a LIE on the development Mac, where rule 2 would then have fired on every local full pass. Where the predicate is false the unit is judged normally, rule 2 included; an unevaluable predicate is treated as APPLYING and says so rather than failing open. Five cases (S18a-e) cover it, including that a six-column row still means exactly what it did before.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T033915Z-df18e8fe`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T033915Z-df18e8fe --disposition "<what you decided or did>"
