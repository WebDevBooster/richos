# Escalation: Two CI hooks are wired in the plugin manifest but not on the engine's seated surface, and main still owes it

- id: `esc-20260910T094854Z-e0b336c8`
- raised: 2026-09-10T09:48:54Z
- from: zach-opus-inf1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-inf1` (branch `zach-opus-inf1`)
- head: `ac893530c880675b3441fa6e26660abe2f12e367`
- state: **work-complete**
- for: lead

## The question

Who wires guard-ci-red-lands.sh and session-start-ci-surface.sh into engine/.claude/settings.local.json — the agent holding the CI work, or the next lander?

## What was already tried

Derived the inventory set with grep -rln guard-stale-staging engine/ while registering my own TaskStop gate; hook-staleness case 11 named all three of us. I wired mine. Verified main's copy at d5b718ae registers neither of the other two, so it is owed on main, not just in my base. guard-ci-red-lands.sh is explicitly outside my scope and another agent holds it right now, so I did not touch either.

## Proceeding meanwhile

My own gate is registered on both surfaces; hook-staleness is 27 passed with no name of mine in the remaining failure.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T094854Z-e0b336c8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T094854Z-e0b336c8 --disposition "<what you decided or did>"
