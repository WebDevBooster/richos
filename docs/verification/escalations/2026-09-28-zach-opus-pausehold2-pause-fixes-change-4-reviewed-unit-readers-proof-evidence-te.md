# Escalation: Pause fixes change 4 reviewed unit readers; proof-evidence.test.py stays red until their qualification digests are renewed

- id: `esc-20260928T055205Z-b3b2025b`
- raised: 2026-09-28T05:52:06Z
- from: zach-opus-pausehold2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-pausehold2` (branch `cc/zach-opus-pausehold2`)
- head: `46ad7e394afee95a0e4f42a44fb063294b44b3b8`
- state: **proceeding**
- for: lead

## The question

Who renews docs/development/verification-input-qualifications.json for workspaces.py (22 units), proc_tree.py (19), worker_tokens.py (19) and pause_protocol.py (14) when this branch lands: me (digest update plus a review note on the new inputs: ps table, agent-hold state dir, a detached watchdog), or Codex, whose reviews those are?

## What was already tried

Ran proof-run.test.sh on my branch: 35 subtests of test_production_recipes_reject_known_shared_and_fixture_tool_omissions raise UnqualifiedReader (changed unit reader requires qualification: richos/engine/scripts/lib/proc_tree.py). pausehold1's committed workspaces.py already did the same against the merged main.

## Proceeding meanwhile

Building every catch fix and the section 94 harness without touching the qualification file; my handoff lists the exact files whose digests changed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260928T055205Z-b3b2025b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260928T055205Z-b3b2025b --disposition "<what you decided or did>"
