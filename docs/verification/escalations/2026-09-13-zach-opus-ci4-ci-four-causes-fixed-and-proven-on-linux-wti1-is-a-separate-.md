# Escalation: CI: four causes fixed and proven on Linux; WTI1 is a separate INTERMITTENT flake that is NOT fixed

- id: `esc-20260913T224044Z-13ca1557`
- raised: 2026-09-13T22:40:44Z
- from: zach-opus-ci4
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ci4` (branch `cc/zach-opus-ci4`)
- head: `072113a8046c911679ea52bfa2154814c8c1b602`
- state: **work-complete**
- for: lead

## The question

Land the branch and read the next run. If it is red ONLY at contract-integrity.test.sh:WTI, that is the known flake and not a regression from these commits — should it get its own task now, or after the run is otherwise green?

## What was already tried

Reproduced every CI failure on ubuntu:24.04 in Docker and fixed four distinct causes, each red-before/green-after: Layer MT and BR9 canaries depended on a 'claude' process ancestry that no runner has; the hook-start sandbox wrote to the operator's real ledger; a quadratic regex in guard-worktree-removal.sh blew the 60s payload-transport timeout. All 12 previously-red units pass through ci-shard.sh at cae905f0, and non-suite-steps exits 0. WTI1 was run green on Linux 10 times across 10/4/2-core arm64 and emulated x86_64, then caught failing twice under CPU oversubscription — a different mutant each time (M2, then M10).

## Proceeding meanwhile

WTI1 now keeps its harness report on failure, so the next red run names the mutant and the inner cases instead of printing only 'got=1'. The captured failure also shows the harness reporting a case as 'red but NOT at' while printing that same case in its own FAIL list, which is a concrete lead for whoever takes it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260913T224044Z-13ca1557`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260913T224044Z-13ca1557 --disposition "<what you decided or did>"
