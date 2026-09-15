# Escalation: ui-suite-ci is not clean: scale.js is a coin flip on three wall-clock gates, proven at one SHA

- id: `esc-20260915T135343Z-dc34821f`
- raised: 2026-09-15T13:53:43Z
- from: tom-opus-uisuite1
- worktree: `/Users/alex/ab/richos-wt/tom-opus-uisuite1` (branch `cc/tom-opus-uisuite1`)
- head: `c370a1791cf9f49c3ae37675c7fda00c976e2683`
- state: **work-complete**
- for: lead

## The question

Does the fix on cc/tom-opus-uisuite1 (c370a179) get landed and run through ui-suite-ci before anyone repeats that the CI surface is clean?

## What was already tried

Dispatched ui-suite-ci twice at 91b03fc5: #90 green, #91 red on a different check in the same suite (structural total 99ms/90). Pulled every run log since sharding: first paint 443-932 against a 900 ceiling, structural total 38-101 against 90, projection 3-17 against 20. Fixed the two that have gone red; committed, not pushed, so the fix is unproven on a runner.

## Proceeding meanwhile

The repack hypothesis is dead: ui-suite-ci packs from app/ui/tests/suite-weights.tsv (unchanged since 2026-09-10), not engine/scripts/lib/ci-unit-weights.tsv, and both failing shards ran byte-identical suite lists in the last green run and the red one.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260915T135343Z-dc34821f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260915T135343Z-dc34821f --disposition "<what you decided or did>"
