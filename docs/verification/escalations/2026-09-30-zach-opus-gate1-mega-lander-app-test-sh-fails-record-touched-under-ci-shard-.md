# Escalation: mega-lander app.test.sh fails RECORD-TOUCHED under ci-shard before its mutation pass, so its pass is not in the nightly yet

- id: `esc-20260930T210243Z-e8c83d1b`
- raised: 2026-09-30T21:02:43Z
- from: zach-opus-gate1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-gate1` (branch `cc/zach-opus-gate1`)
- head: `68f6669a38406acc596339c5b0cc09fa9d34411c`
- state: **proceeding**
- for: lead

## The question

Who fixes app.test.py writing the machine-wide land locks (~/.claude/state/land-locks, app.test.py line 41) under its sandbox HOME, so the unit passes ci-shard's record canary? Until then it blocks every merge that selects it (a failing check blocks), and adding it to the nightly's gates/workspace-mutants would turn every nightly red.

## What was already tried

Ran bash scripts/ci-shard.sh --only-units mega-lander/tests/app.test.sh on cc/zach-opus-gate1 at 6807a3af: FAIL 96.8 s, RECORD-TOUCHED, record file CHANGED <sandbox home>/.claude/state. The failure is in the behavioral half (app.test.py), which this branch does not change; the three other finding-19 units pass (3/3).

## Proceeding meanwhile

Finding 19 is done for workspaces, create-teammate-worktree and workspace-probes (nightly runs their mutation passes). app.test.sh takes the RICHOS_MUTATION_PASSES switch but is left out of nightly-local.py MUTATION_PASS_UNITS, with a comment saying it joins that list in the change that fixes the record write (commit 68f6669a).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260930T210243Z-e8c83d1b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260930T210243Z-e8c83d1b --disposition "<what you decided or did>"
