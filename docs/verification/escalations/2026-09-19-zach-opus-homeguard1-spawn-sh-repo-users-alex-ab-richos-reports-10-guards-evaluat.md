# Escalation: spawn.sh --repo /Users/alex/ab/richos reports '10 guards evaluated, 10 passed' when NONE of them evaluated anything

- id: `esc-20260919T141956Z-ffce03a9`
- raised: 2026-09-19T14:19:56Z
- from: zach-opus-homeguard1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-homeguard1` (branch `cc/zach-opus-homeguard1`)
- head: `b7d0311e6b9f7867e68bdb6cc575263be09f1e89`
- state: **proceeding**
- for: lead

## The question

Should /Users/alex/ab/richos get an orchestration.config at its root, or should spawn.sh say STOOD DOWN instead of ok when the resolved project dir has not adopted the engine?

## What was already tried

Measured both ways with one payload. guard-model-ceiling.sh on a FABLE spawn (MODEL_CEILING=opus): exit 0 with CLAUDE_PROJECT_DIR=/Users/alex/ab/richos, exit 2 with CLAUDE_PROJECT_DIR=/Users/alex/ab/femcboost. resolve_entity_root says 'not-adopted' for richos: there is no orchestration.config at /Users/alex/ab/richos, only at /Users/alex/ab/richos/richos/engine. spawn.py sets CLAUDE_PROJECT_DIR to the --repo, so every rooted guard takes its silent not-adopted exit and spawn.sh prints ok beside each one. This is pre-existing and affects all ten, not the new guard.

## Proceeding meanwhile

The new §61 guard refuses correctly from a femcboost-seated session, which is where Rich actually dispatches from; verified exit 2 on the real route1 payload.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T141956Z-ffce03a9`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T141956Z-ffce03a9 --disposition "<what you decided or did>"
