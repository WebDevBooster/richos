# Escalation: Round 12: three certification items REFUSED with reasons, and one that cannot be satisfied from a worktree

- id: `esc-20260910T195115Z-da34eb48`
- raised: 2026-09-10T19:51:15Z
- from: zach-opus-fix1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-fix1` (branch `cc/zach-opus-fix1`)
- head: `f958da91b3359c0b6409dbeced1c834cb69f882e`
- state: **work-complete**
- for: lead

## The question

Do Sage and Frank accept a reasoned refusal of (a) killing an agent's background children at its terminal event, (b) a live-turn-end demonstration of the land-disposition notice, and (c) repointing the operator's plugin install?

## Correction, round 13 (2026-09-10, zach-fable-fix2)

The refusal of item (a) — killing an agent's background children at its
terminal event — stands, and both reviewers accepted it. Its **stated reason**
was wrong and is corrected here beside the original: the lead's record of this
escalation said *"the held lock those children cause is the protection, not the
problem."* It is not. On `zach-opus-q1` the reaper witnessed the native worktree
`registered and unlocked` at 13:11:22Z and the agent restarted at 14:34:37Z —
the lock was **absent for 83 minutes** while its children lived
(`grep a57075d0698120f83 ~/.claude/state/worktree-ledger.jsonl`;
`restart-after-terminal-measure.py --locks`, line (c)). What protects a
workspace with a live child in it is row 12 of the decision table (the process
probe, `processes_using`, fails closed and holds on any pid with its cwd or a
handle in the tree), row 5 (an open post-terminal run, from two sources), and
the write barrier — not the lock. The reason the engine does not kill is the
one that was always sufficient: killing would add authority to remove a hold,
which is the wrong direction.

## What was already tried

Everything else on both certification lists is implemented, tested and mutation-proven; these three are named in the final report with the argument for each.

## Proceeding meanwhile

The branch is complete and committed; nothing depends on the answer.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T195115Z-da34eb48`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T195115Z-da34eb48 --disposition "<what you decided or did>"
