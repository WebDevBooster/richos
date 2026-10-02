# Escalation: zach-opus-integ3: ci-shard.test.sh S15i fails on cc/zach-opus-tmpvanish1 itself, so the integration land's merge gate will refuse it

- id: `esc-20261002T125030Z-7da46c85`
- raised: 2026-10-02T12:50:30Z
- from: zach-opus-integ3
- worktree: `/Users/alex/ab/richos-wt/zach-opus-integ3` (branch `cc/zach-opus-integ3`)
- head: `113990ed36fe72e08f376c5809a36b5355fd4a0a`
- state: **proceeding**
- for: lead

## The question

Should tmpvanish1's S15i failure be fixed before the land (by narrowing S15i to 'no row of the UNIT's allocation reaches the operator's ledger', since ci-shard.sh now records its own run folder there by design), or should tmpvanish1 be dropped from this integration? The brief limits me to fixing what the combination broke, and this is not a combination break.

## What was already tried

Proof run of 6293bdd2f..HEAD on cc/zach-opus-integ3: engine scripts/ci-shard.test.sh FAIL, 57 passed, 1 failed: S15i 'the first scratch_new reached the operator's config' (diff shows ./state/scratch-ledger.jsonl appearing in the fixture operator's config). Ran ci-shard.test.sh on an export of cc/zach-opus-tmpvanish1 (bd303b166) alone: the same S15i failure. Cause: S15i copies lib/scratch.sh into its synthetic engine, so tmpvanish1's ci-shard.sh (rule 2: allocate the run folder with scratch_new) now writes its own ledger row into the operator's config that S15i asserts stays byte-for-byte unchanged. S15i (2f5ad514a) predates tmpvanish1; main's scratch.sh changes since tmpvanish1's base do not touch ledger resolution. Proof run evidence: /Volumes/E1TB/state/richos/proof-runs/a633f2bfc429/20261002T112222Z-hy9w0ga6/15-engine-scripts-ci-shard.test.sh.log

## Proceeding meanwhile

Finishing the proof run and reporting every suite; not changing tmpvanish1's code or S15i.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T125030Z-7da46c85`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T125030Z-7da46c85 --disposition "<what you decided or did>"
