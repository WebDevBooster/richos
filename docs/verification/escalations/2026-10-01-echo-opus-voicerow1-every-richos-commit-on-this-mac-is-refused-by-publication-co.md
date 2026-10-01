# Escalation: Every richos commit on this Mac is refused by publication-completeness over a richos-hq hunt file committed at 22:29 tonight

- id: `esc-20261001T213951Z-67efb205`
- raised: 2026-10-01T21:39:51Z
- from: echo-opus-voicerow1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-voicerow1` (branch `cc/echo-opus-voicerow1`)
- head: `c6cde6cc94573b9c78b8c9c695e535b9b0b90c11`
- state: **proceeding**
- for: lead

## The question

Will you add an instance-mechanism line (one operator's hunt evidence, not a customer capability) to richos-hq docs/audits/2026-09-29-hunt/part-3-codex-evidence-v2/probes-v2.py, or say which of the guard's three ways through I should take from my richos workspace?

## What was already tried

git commit in /Users/alex/ab/richos-wt/echo-opus-voicerow1 (branch cc/echo-opus-voicerow1) was refused at PreToolUse by the engine's publication-completeness check: [MISPLACED] richos-hq/docs/audits/2026-09-29-hunt/part-3-codex-evidence-v2/probes-v2.py is an executable mechanism in the PRIVATE tree that reads the public contract .ceo-todos. The file is in /Users/alex/ab/richos-hq main, committed in 18ff214e (2026-10-01 22:29 +0100, hunt part 3 Codex v2 evidence). My change touches none of it. The guard's own text says the excuse lives with the file, and I have no workspace in richos-hq, so I did not edit it, and I did not add an exemption to the public tree's .richos/publication-completeness for a private file I do not own.

## Proceeding meanwhile

The voice-row fix and its tests are done and green in the workspace, uncommitted only because of this refusal. I am building the real-listener check (lab Mac, production client, recorded WAV) and will commit everything the moment the check passes.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T213951Z-67efb205`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T213951Z-67efb205 --disposition "<what you decided or did>"
