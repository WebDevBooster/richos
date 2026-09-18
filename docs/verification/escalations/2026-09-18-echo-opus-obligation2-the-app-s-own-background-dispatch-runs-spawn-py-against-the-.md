# Escalation: The app's own background dispatch runs spawn.py against the engine's nine operator guards, and one of them refuses it today

- id: `esc-20260918T163906Z-60bd48e1`
- raised: 2026-09-18T16:39:06Z
- from: echo-opus-obligation2
- worktree: `/Users/alex/ab/richos-wt/echo-opus-obligation2` (branch `cc/echo-opus-obligation2`)
- head: `9e99ded34ce21b7296fcffe82b2dbf040d5e2a78`
- state: **work-complete**
- for: lead

## The question

Should the RichOS app's prepare/spawn path evaluate the engine's operator guards at all, and if it should, what is the front desk supposed to do when one of them refuses over the developer session's own standing systems?

## What was already tried

Measured, not inferred, on every run today including two on the real provider. richos_work.prepare reaches its last step and then runs spawn.py with cwd and project-dir set to the APP's coordination root (RICHOS_ENTITY_ROOT), so spawn.py collects every PreToolUse[Agent] guard from engine/hooks/hooks.json. Result on this Mac: 'spawn: refused by 1 of 9 guard(s) - NOTHING WAS CREATED', guard-owned-state.sh, over 'system: ci ... PAUSED WebDevBooster/richos'. The other eight pass. That guard's two escape hatches are 'dispatch somebody at it' and an owned-state-ack: line in the spawn prompt; the front desk has neither, and the brief prepare writes is not a place the app can add a prompt line. Logs: docs/verification/first-words-2026-09-18-logs/run-D-*.log and dispatch-only-no-model-turns.log.

## Proceeding meanwhile

My slice is complete and this blocks none of it: everything up to the dispatch step is measured green, and the probe scores reaching that step rather than passing the guards. What it means for the product is that a real background assignment on this machine today would die at spawn with an operator-session message, and that is somebody's call rather than mine.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T163906Z-60bd48e1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T163906Z-60bd48e1 --disposition "<what you decided or did>"
