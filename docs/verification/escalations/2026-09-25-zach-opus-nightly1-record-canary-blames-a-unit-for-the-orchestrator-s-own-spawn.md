# Escalation: Record canary blames a unit for the orchestrator's own spawns; the fix you specified would drop the 2026-09-11 protection

- id: `esc-20260925T214717Z-f6def5b6`
- raised: 2026-09-25T21:47:17Z
- from: zach-opus-nightly1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-nightly1` (branch `cc/zach-opus-nightly1`)
- head: `823ba77b103a34fd54e669708f4a1f2bf801439e`
- state: **proceeding**
- for: lead

## The question

May I build writer attribution instead? Registry and ledger writers record their process ancestry (pid plus start time), and the canary blames only entries whose chain passes through the unit's pid or is orphaned to launchd. Or do you prefer the key-scoped version, knowingly giving up leaks that carry a real key?

## What was already tried

Read record-canary.sh. Its header already names real spawns as a known false-positive vector. The watched records (workspace registry events and agent files, worktree-ledger rows) carry no writer identity. The 2026-09-11 incident it exists for was a unit writing a terminated row for a REAL agent key, so attributing by 'the test's own keys' would pass exactly that leak. Env-var tagging fails open under env -i. Parent ancestry alone can't separate lead from subagent, because both run in the same claude process; the unit's own pid in the chain can.

## Proceeding meanwhile

Rebuild 20260925T214655Z-4b9f7dfd from 823ba77b is running now, relying on your hold during its workspace-mutants gate. That gate runs the unit alone via --only-units, so it doubles as the isolated retry. No canary change is in this build.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T214717Z-f6def5b6`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T214717Z-f6def5b6 --disposition "<what you decided or did>"
