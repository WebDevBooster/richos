# Escalation: native-ios-app.test.sh cannot be committed: publication guard matches its existing line 118

- id: `esc-20260925T111436Z-c9e92d11`
- raised: 2026-09-25T11:14:36Z
- from: zach-opus-results1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-results1` (branch `cc/zach-opus-results1`)
- head: `63141e8a2ab8000ae9f649b7db54613b82a1189c`
- state: **proceeding**
- for: lead

## The question

Allowlist richos/app/scripts/native-ios-app.test.sh in .publication-boundary, or reword its line 118 NOT RUN message (it quotes the CEO's 'Only before nightlies' and a private record quotes the whole line), so the A8 failure-naming change can land?

## What was already tried

Committed the other three iOS suites; dropped the 13-line A8 change (native-ios-app.test.sh) because guard-publication-commits.sh refuses any commit staging that file: 30 words verbatim from a private record, all pre-existing on main.

## Proceeding meanwhile

Everything else is committed on cc/zach-opus-results1; running the proof selection. A8 only runs before nightlies; its failure still prints the bundle path in the FAIL detail.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260925T111436Z-c9e92d11`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260925T111436Z-c9e92d11 --disposition "<what you decided or did>"
