# Escalation: Land checks: run the workspace-spec mutation pass on every land, or only before nightlies?

- id: `esc-20260923T123440Z-b5371531`
- raised: 2026-09-23T12:34:41Z
- from: tom-opus-speed1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-speed1` (branch `cc/tom-opus-speed1`)
- head: `353a15011b714428076dfea9f52941519a56a5c8`
- state: **proceeding**
- for: ceo

## The question

workspace-spec-fourteen.test.sh re-runs its checks once per each of 86 deliberately broken copies of the workspace code (its mutation pass), to prove every check can still fail. After today's change that pass costs about 12 minutes of the whole Mac (measured 792 s alone, 11.6 min of it the pass), and it runs on every land that touches the workspace code or a hook the suite names (28 of the last 78 engine lands). Keep the pass on every such land, or run it only before nightlies (like A8), so a land that stops a check from catching a broken property is found at the next nightly instead of at the land? The suite's 14 checks themselves (84 s) would still run on every land either way.

## What was already tried

Each broken copy now stops at the check it proves instead of running all 14 (2811.7 s in the recorded inventory to 792 s on this Mac); the workspaces suite's pass went from 9103 to 291 CPU-seconds.

## Proceeding meanwhile

Nothing waits on this; the pass stays on every land until the CEO decides.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260923T123440Z-b5371531`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260923T123440Z-b5371531 --disposition "<what you decided or did>"
